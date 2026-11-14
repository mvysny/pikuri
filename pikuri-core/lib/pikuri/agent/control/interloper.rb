# frozen_string_literal: true

module Pikuri
  class Agent
    module Control
      # Mid-loop host→agent injection queue. Every {Agent} builds its own, and
      # a host (TUI, web client) enqueues from any thread while the agent runs:
      #
      #   agent.interloper.inject_user_message('also check the tests')   # a user turn
      #   agent.interloper.inject_system_message('<skill name="tdd">…</skill>')   # reference text
      #
      # The agent drains it at turn start and once each tool batch is
      # answered: an injection made while idle lands ahead of the next turn's
      # message, one made mid-turn reaches the next round-trip.
      # {Agent#drain_interloper} says how each {Item#kind} lands. A host
      # showing a "2 queued" badge reads {#size} or sets {#on_change}. Why a
      # running turn takes a user message at all: +design/decisions.md+
      # +D_mid_turn_user_message+.
      #
      # Sub-agents are private to the parent, so a child's queue stays empty —
      # injection is directed at the main agent, where {Control::Cancellable}
      # is shared by the whole tree.
      #
      # == Implementation details
      #
      # Never drained *inside* a tool batch: an assistant message carrying
      # tool_calls and the +:tool+ messages answering it are one unit on the
      # wire, and a message appended between them is rejected or mangled (see
      # {Agent#tool_batch_complete?}).
      #
      # Thread-safe: a +Mutex+-guarded +Array+. {#on_change} fires outside the
      # lock, so a callback may re-enter the interloper.
      class Interloper
        # A queued injection: +kind+ (+:user+ or +:system+) selects the drain
        # path; +content+ is the message text (+""+ for an attachment-only
        # user message), +attachments+ the files shown with it, always empty
        # for +:system+.
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

        # Called with the new pending count after each injection, and with +0+
        # after a {#drain!} that empties a non-empty queue (an empty drain, the
        # hot path, stays silent); +nil+ disables it. Runs on the mutating
        # thread, so a callback feeding another thread should hand off only
        # immutable data.
        #
        # @return [Proc, nil]
        attr_accessor :on_change

        # Enqueue a +:user+ mid-loop turn, the same message {Agent#run_loop}
        # takes, e.g. an image dropped while the agent works:
        #
        #   interloper.inject_user_message('and this one?', attachments: [png])
        #
        # Unlike {Agent#run_loop}, nothing here can refuse an attachment the
        # model can't see: this runs on the host's thread with no agent, and
        # raising at the drain would end the running turn over a picture. The
        # drain withholds it instead, with a note in the text the model reads
        # ({ChatTransport#modalities}). A host wanting an error up front checks
        # +agent.transport.modalities+ before injecting.
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

          content = '' if !attachments.empty? && content.to_s.strip.empty?
          enqueue(:user, content, attachments: attachments)
        end

        # Enqueue a +:system+ reference block — host-loaded skill text or other
        # retrieved context, not a user turn.
        #
        # @param content [String] non-blank reference text; an own semantic tag
        #   is kept, the +<system-reminder>+ envelope nests around it
        # @raise [ArgumentError] if +content+ is +nil+/blank
        # @return [void]
        def inject_system_message(content)
          enqueue(:system, content)
        end

        # @return [Boolean] whether the queue holds a pending injection
        def pending?
          @mutex.synchronize { !@items.empty? }
        end

        # @return [Integer] number of pending injections; a snapshot that may
        #   have drained by the time the caller reads it
        def size
          @mutex.synchronize { @items.size }
        end

        # Atomically take and remove all pending items.
        #
        # @return [Array<Item>] items in delivery order; +[]+ when empty
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

        private

        # @param kind [Symbol] +:user+ or +:system+
        # @param content [String, nil]
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
