# frozen_string_literal: true

module Pikuri
  class Agent
    module Control
      # Mid-loop host→agent injection queue. Every {Agent} builds its own; a
      # host (TUI, web client) reaches it as {Agent#interloper} and enqueues
      # from any thread while the agent runs:
      #
      #   agent.interloper.inject_user_message('also check the tests')
      #
      # The +Agent+ drains it once the running tool batch is answered — the only
      # point in ruby_llm's loop where conversation state is consistent — and
      # the next round-trip reacts to what was injected.
      #
      # == Two kinds
      #
      # Each item carries a {Item#kind}, driving how {Agent#drain_interloper}
      # lands it:
      #
      # - +:user+ ({#inject_user_message}) — a mid-loop user turn, attachments
      #   and all: appended verbatim, emits +Event::UserTurn(mid_loop: true)+,
      #   and runs the {Extension#on_user_message} dispatch (prefetch/record
      #   like an initial turn).
      # - +:system+ ({#inject_system_message}) — host-supplied reference text
      #   (a loaded skill, retrieved context): appended wrapped in
      #   +<system-reminder>+, emits +Event::SystemInjected+, and runs *no*
      #   +on_user_message+ dispatch and no +UserTurn+ (it's not a user turn).
      #
      # Both reach the wire as +role: :user+ — the kinds differ in dispatch and
      # envelope, not in role. +:system+ names the *role the text plays*, and
      # {Agent#append_reference_block} says why the wire role can't match it.
      #
      # Only a host running the agent on a worker thread has anyone to inject;
      # the bundled +bin/pikuri-*+ read stdin synchronously and leave it empty.
      #
      # == Delivery boundary
      #
      # Delivery is at the end of a tool batch, *not* the LLM HTTP call: an
      # injection made mid-response takes effect on the *next* round-trip, once
      # the model has committed to the current response's tool calls. Never
      # *inside* a batch — an assistant message carrying tool_calls and the
      # +:tool+ messages answering it are one unit on the wire, and a message
      # appended between them is rejected or mangled (see
      # {Agent#tool_batch_complete?}). Same
      # "gentle" semantic {Control::Cancellable} promises — the cleanest
      # cross-provider point (no in-flight subprocess, no half-built response).
      # Controls are reset only at turn start, never on a mid-loop injection,
      # so "cancel-then-inject" and "refresh-budget-by-injecting" can't arise.
      #
      # == Change notification
      #
      # A host rendering the pending count reactively (a "3 waiting" badge)
      # sets {#on_change} instead of polling {#size}. It fires whenever the
      # count changes — once per {#inject_user_message}, once per {#drain!}
      # that empties a non-empty queue (an empty-queue drain, the hot path,
      # stays silent) — with the new count, outside the lock. A host-side hook,
      # not an {Agent} listener event: the count changes on the injecting
      # thread, off the agent-thread-confined stream. It pushes the count
      # rather than signalling a change to re-read, since the interloper
      # exposes no race-free snapshot.
      #
      # == Sub-agent semantics
      #
      # Sub-agents are private to the parent; the host has no handle to them,
      # so a child's queue stays empty. Contrast {Control::Cancellable}, shared by reference so the
      # parent's stop propagates to the whole tree — cancellation is global,
      # injection is directed at the main agent.
      #
      # Thread-safe: {#inject_user_message}, {#inject_system_message}, {#peek},
      # {#pending?}, {#size}, and {#drain!} are a +Mutex+-guarded +Array+
      # (chosen over +Thread::Queue+, which exposes no snapshot for {#peek}).
      # {#on_change} fires outside the lock so a re-entrant or blocking callback
      # can't deadlock.
      class Interloper
        # A queued injection: +kind+ (+:user+ or +:system+) selects the drain
        # path; +content+ is the message text (+""+ for an attachment-only
        # user message), +attachments+ the files shown with it, always empty
        # for +:system+. Producers are the two +inject_*+ methods; the
        # consumer is {Agent#drain_interloper}.
        Item = Data.define(:kind, :content, :attachments) do
          # @param kind [Symbol]
          # @param content [String]
          # @param attachments [Array<Pikuri::Attachment>]
          def initialize(kind:, content:, attachments: [])
            super(kind: kind, content: content, attachments: attachments.dup.freeze)
          end
        end

        def initialize
          @mutex = Mutex.new
          @items = []
          @on_change = nil
        end

        # Optional host callback invoked with the new pending count whenever it
        # changes (after {#inject_user_message}, and after a {#drain!} that
        # empties a non-empty queue). +nil+ (default) disables it. Runs
        # *outside* the queue lock, on the mutating thread, so a callback
        # feeding another thread should hand off only immutable data.
        #
        # @return [Proc, nil]
        attr_accessor :on_change

        # Enqueue a +:user+ mid-loop turn (any thread; +Mutex+-guarded), the
        # same message {Agent#run_loop} takes, e.g. an image dropped while the
        # agent works:
        #
        #   interloper.inject_user_message('and this one?', attachments: [png])
        #
        # Fires {#on_change} with the new count, outside the lock.
        #
        # Unlike {Agent#run_loop}, nothing here can refuse an attachment the
        # model can't see: this runs on the host's thread with no agent, and
        # raising at the drain would end the running turn over a picture. The
        # drain withholds it instead, with a note in the text the model reads
        # ({Agent#modalities}). A host wanting an error up front checks
        # +agent.modalities+ before injecting.
        #
        # @param content [String, nil] the user's text; may be blank only when
        #   +attachments+ are given
        # @param attachments [Array<Pikuri::Attachment>] files shown with it
        # @raise [ArgumentError] if there is neither text nor an attachment — a
        #   blank injection would poison the chat history like a blank turn —
        #   or an attachment is not a {Pikuri::Attachment}
        # @return [void]
        def inject_user_message(content = nil, attachments: [])
          unless attachments.all?(Pikuri::Attachment)
            raise ArgumentError, "attachments must be Pikuri::Attachments, got #{attachments.map(&:class)}"
          end
          return enqueue(:user, content) if attachments.empty?

          enqueue(:user, content.to_s.strip.empty? ? '' : content, attachments: attachments)
        end

        # Enqueue a +:system+ reference block — host-loaded skill text or
        # other retrieved context injected on the host's own initiative, not a
        # user turn (any thread; +Mutex+-guarded). Fires {#on_change}.
        #
        # @param content [String] non-blank reference text (e.g. a rendered
        #   skill block); an own semantic tag is kept, the +<system-reminder>+
        #   envelope nests around it
        # @raise [ArgumentError] if +content+ is +nil+/blank
        # @return [void]
        def inject_system_message(content)
          enqueue(:system, content)
        end

        # Non-destructive snapshot of the queue in delivery order, for a host
        # rendering a "pending" affordance. Safe from any thread.
        #
        # @return [Array<Item>] copy of the pending items; never shares state
        #   with the internal buffer
        def peek
          @mutex.synchronize { @items.dup }
        end

        # @return [Boolean] whether the queue holds a pending injection;
        #   observable from any thread
        def pending?
          @mutex.synchronize { !@items.empty? }
        end

        # @return [Integer] number of pending injections; a snapshot from any
        #   thread (may have drained by the time the caller reads it)
        def size
          @mutex.synchronize { @items.size }
        end

        # Atomically take and remove all pending items. Called by {Agent}'s
        # +after_message+ wiring, once a tool batch is complete. Returns +[]+ when empty (the hot path) —
        # an empty drain does *not* fire {#on_change}; a drain that empties a
        # non-empty queue fires it with +0+, outside the lock.
        #
        # @return [Array<Item>] items in delivery order; empty when the queue
        #   is empty
        def drain!
          items = @mutex.synchronize do
            next [] if @items.empty?

            taken = @items.dup
            @items.clear
            taken
          end
          @on_change&.call(0) unless items.empty?
          items
        end

        # @return [String] short label for {Agent#to_s}, reflecting the
        #   pending count.
        def to_s
          pending = size
          pending.zero? ? 'Interloper' : "Interloper(#{pending} pending)"
        end

        private

        # Shared enqueue for both +inject_*+ methods: validate, push a typed
        # {Item}, fire {#on_change} outside the lock.
        #
        # @param kind [Symbol] +:user+ or +:system+
        # @param content [String]
        # @param attachments [Array<Pikuri::Attachment>] non-empty excuses a
        #   blank +content+
        # @raise [ArgumentError] if +content+ is +nil+/blank with no attachments
        # @return [void]
        def enqueue(kind, content, attachments: [])
          raise ArgumentError, "content must not be blank, got #{content.inspect}" \
            if attachments.empty? && (content.nil? || content.to_s.strip.empty?)

          item = Item.new(kind: kind, content: content, attachments: attachments)
          count = @mutex.synchronize { @items << item; @items.size }
          @on_change&.call(count)
          nil
        end
      end
    end
  end
end
