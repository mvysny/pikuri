# frozen_string_literal: true

module Pikuri
  class Agent
    # How many LLM requests pikuri lets fly against one inference server at a
    # time. A host sizes the servers it knows are small; everything else is
    # unlimited:
    #
    #   ServerPermits.limit('http://localhost:8080', 1)      # llama-server --parallel 1
    #   ServerPermits.limit('https://api.openai.com/v1', nil) # explicit "doesn't care"
    #
    # Usually a host configures nothing: {Agent}'s +/props+ probe reads
    # llama.cpp's own +total_slots+ and seeds it through {.default}, so N agents
    # against the default local server already queue correctly. {.limit} wins
    # over any such default.
    #
    # {RequestThrottle} is the acquire site — one permit per HTTP request, held
    # for the whole streamed response.
    #
    # == Why a process-wide registry
    #
    # The resource being rationed is the *server*, so the limiter is scoped to
    # the server (+DECISIONS.md+ +D_rate_limiter_scope+, +D_llm_request_throttle+).
    # Anything narrower defeats it: a permit pool a host builds per session, or
    # per agent tree, still lets two independently-built agents hammer one
    # llama.cpp exactly as before — and a ctor argument is one more field the
    # forwarding sites ({SubAgent::SubAgentTool} and friends, which rebuild a
    # child's transport with +parent.transport.with(...)+) can silently drop.
    # A registry has nothing to forward.
    #
    # Keys are normalized as {ChatTransport.from_openai_server} normalizes a
    # server (a trailing +/+ and +/v1+ stripped), so +http://x:8080+,
    # +http://x:8080/v1+ and +http://x:8080/v1/+ are one server.
    #
    # Thread-safe.
    module ServerPermits
      # A counting semaphore whose wait is cancellable, obtained from {.for}
      # rather than built directly:
      #
      #   ServerPermits.for(base).acquire(cancellable: agent.cancellable) { post_request }
      #
      # +permits+ +nil+ means unlimited, and then {#acquire} is a bare +yield+ —
      # which is what makes an unsized (cloud) server free of every lock here.
      #
      # Thread-safe.
      class Semaphore
        # @return [Integer, nil] how many permits exist; +nil+ for unlimited.
        attr_reader :permits

        # @param permits [Integer, nil] concurrent permits, or +nil+ for
        #   unlimited.
        def initialize(permits)
          @permits = permits
          @available = permits
          @mutex = Mutex.new
          @cv = ConditionVariable.new
        end

        # Run the block holding one permit, waiting for one first.
        #
        # @param cancellable [Control::Cancellable, nil] polled while waiting, so
        #   a Ctrl+C lands on a request parked in the queue rather than after the
        #   server finally answers it.
        # @yield with the permit held
        # @return [Object] the block's value
        # @raise [Control::Cancellable::Cancelled] if cancelled before the permit
        #   was acquired (nothing was sent, so the turn unwinds having done
        #   nothing)
        def acquire(cancellable: nil)
          return yield if @permits.nil?

          take(cancellable)
          begin
            yield
          ensure
            release
          end
        end

        # @return [Integer, nil] permits not currently held; +nil+ for unlimited.
        def available
          @permits.nil? ? nil : @mutex.synchronize { @available }
        end

        # @return [String] +"1/1 permits"+ / +"unlimited"+.
        def to_s
          @permits.nil? ? 'unlimited' : "#{available}/#{@permits} permits"
        end

        private

        # @param cancellable [Control::Cancellable, nil]
        # @return [void]
        def take(cancellable)
          @mutex.synchronize do
            loop do
              cancellable&.check!
              if @available.positive?
                @available -= 1
                return
              end

              # A timed wait re-checking the flag, not a plain +wait+, and the
              # same slice for the same reason as {Control::Cancellable#sleep}:
              # +cancel!+ must stay a bare flag write callable from a SIGINT
              # trap, so it can signal no condition variable and the waiting
              # side has to poll.
              @cv.wait(@mutex, Control::Cancellable::SLICE_SECONDS)
            end
          end
        end

        # @return [void]
        def release
          @mutex.synchronize do
            @available += 1
            # +broadcast+, not +signal+: a +signal+ can wake precisely the
            # waiter that is about to raise {Cancelled}, and the permit is then
            # stranded until someone else releases one. Wake-ups are cheap at
            # these rates.
            @cv.broadcast
          end
        end
      end

      # The permit object for a server nobody sized. Shared, and frozen so a
      # stray attempt to hold state on it raises rather than silently rationing
      # the wrong server.
      #
      # @return [Semaphore]
      UNLIMITED = Semaphore.new(nil).freeze

      @sizes = {}
      @explicit = {}
      @semaphores = {}
      @mutex = Mutex.new

      class << self
        # Size a server, overriding whatever the +/props+ probe found.
        #
        #   ServerPermits.limit('http://localhost:8080', 1)
        #
        # @param server [String] the server's base URL, with or without +/v1+
        # @param permits [Integer, nil] concurrent requests to allow; +nil+ for
        #   unlimited
        # @return [void]
        # @raise [ArgumentError] on a non-positive or non-Integer +permits+
        def limit(server, permits)
          store(server, permits, explicit: true)
        end

        # Size a server *unless* it is already sized — the +/props+ probe's door,
        # where first probe wins and a host's {.limit} always wins.
        #
        # @param server [String] the server's base URL, with or without +/v1+
        # @param permits [Integer, nil] concurrent requests to allow
        # @return [void]
        # @raise [ArgumentError] on a non-positive or non-Integer +permits+
        def default(server, permits)
          store(server, permits, explicit: false)
        end

        # The permit object for +server+ — {UNLIMITED} for a server nobody
        # sized, which is every cloud endpoint and any provider with no
        # configurable base.
        #
        # @param server [String, nil] the server's base URL; +nil+/blank is
        #   unlimited
        # @return [Semaphore]
        def for(server)
          key = key_for(server)
          return UNLIMITED if key.nil?

          @mutex.synchronize do
            size = @sizes[key]
            next UNLIMITED if size.nil?

            @semaphores[key] ||= Semaphore.new(size)
          end
        end

        # @return [Hash{String => Integer, nil}] every sized server, keyed as
        #   {.key_for} normalizes it; a +nil+ value is an explicit "unlimited".
        def sizes
          @mutex.synchronize { @sizes.dup }
        end

        # Forget every size and every permit object — a spec's +after+ hook, so
        # one example's server cannot ration another's.
        #
        # @return [void]
        def reset!
          @mutex.synchronize do
            @sizes.clear
            @explicit.clear
            @semaphores.clear
          end
          nil
        end

        # @param server [String, nil] a server base URL
        # @return [String, nil] the registry key — +server+ without a trailing
        #   +/+ or +/v1+ — or +nil+ when there is no server to key on.
        def key_for(server)
          key = server.to_s.strip.chomp('/').delete_suffix('/v1')
          key.empty? ? nil : key
        end

        private

        # @param server [String]
        # @param permits [Integer, nil]
        # @param explicit [Boolean] whether a host asked for this size (a
        #   probe's default never overrides one, nor a default already seeded)
        # @return [void]
        def store(server, permits, explicit:)
          unless permits.nil? || (permits.is_a?(Integer) && permits.positive?)
            raise ArgumentError, "permits must be a positive Integer or nil, got #{permits.inspect}"
          end

          key = key_for(server)
          raise ArgumentError, "no server to size in #{server.inspect}" if key.nil?

          @mutex.synchronize do
            next if !explicit && (@explicit[key] || @sizes.key?(key))

            # Dropping the memoized semaphore is what makes a re-size take
            # effect ({RequestThrottle} looks one up per request). Requests
            # already holding a permit release into the old object, so a re-size
            # under load can briefly overlap old and new permits — hosts size at
            # boot, and an advisory overlap beats blocking one.
            @semaphores.delete(key) unless @sizes[key] == permits
            @sizes[key] = permits
            @explicit[key] = true if explicit
          end
          nil
        end
      end
    end
  end
end
