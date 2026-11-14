# frozen_string_literal: true

module Pikuri
  class Agent
    module Control
      # A one-shot slot that one thread waits on until another fills it, or
      # until the turn is cancelled. Built for a host confirmer whose human
      # answers on another thread (a TUI's UI thread, a web request):
      #
      #   def ask(request:, cancellable:)
      #     handoff = Pikuri::Agent::Control::Handoff.new(cancellable)
      #     ui.submit { show_dialog(request) { |decision| handoff.complete(decision) } }
      #     handoff.await   # the decision, or Cancellable::Cancelled on a cancel
      #   ensure
      #     ui.submit { close_dialog }
      #   end
      #
      # Any {Cancellable#cancel!} reaches the parked {#await}, wherever it was
      # issued, so the host needs no cancel hook of its own on the confirmer.
      #
      # == Implementation details
      #
      # {#complete} wakes {#await} through a +ConditionVariable+; a cancel is
      # polled every {Cancellable::SLICE_SECONDS} instead, so {Cancellable#cancel!}
      # stays a bare flag write that is safe from a SIGINT trap. A cancel wins over
      # an answer landing in the same slice, as in {Cancellable#sleep}.
      #
      # Thread-safe.
      class Handoff
        # @param cancellable [Cancellable] the turn's token; {#await} raises
        #   once it trips.
        def initialize(cancellable)
          @cancellable = cancellable
          @mutex = Mutex.new
          @filled = ConditionVariable.new
          @done = false
          @value = nil
        end

        # Fill the slot and wake {#await}. Callable from any thread except a
        # signal trap, since it takes a lock.
        #
        # @param value [Object] what {#await} answers; may be +nil+.
        # @return [void]
        # @raise [RuntimeError] when already completed — one answer per wait.
        def complete(value)
          @mutex.synchronize do
            raise "#{self.class} already completed with #{@value.inspect}" if @done

            @value = value
            @done = true
            @filled.signal
          end
        end

        # Block until {#complete} is called, and answer its value. Returns at
        # once when the slot is already filled.
        #
        # @return [Object] the value {#complete} was given.
        # @raise [Cancellable::Cancelled] when the token trips, before or
        #   during the wait.
        def await
          @mutex.synchronize do
            loop do
              @cancellable.check!
              return @value if @done

              @filled.wait(@mutex, Cancellable::SLICE_SECONDS)
            end
          end
        end
      end
    end
  end
end
