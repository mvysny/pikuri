# frozen_string_literal: true

module Pikuri
  class Agent
    module Listener
      # Logs the conversation's context-window consumption per assistant
      # turn via +Pikuri.logger_for('Tokens')+ — a running headline to catch
      # growth before the provider raises
      # +RubyLLM::ContextLengthExceededError+. Consumes {Event::Tokens} (one
      # line each) and {Event::HistoryLoaded} (seed the snapshot, see
      # {#seed_snapshot}); every other variant is a no-op.
      #
      # == Log line shape
      #
      #   msg #1: ctx=6.8k  Δ+6.8k  ↑6.8k  ↓0.0k
      #   msg #2: ctx=8.4k  Δ+1.6k  ↑1.0k  ↓0.6k
      #   [researcher 0] msg #1: ctx=4.2k  ...            # sub-agent (Agent#id)
      #
      # +ctx+ is the through-this-turn snapshot (+input + cached +
      # cache_creation + output+; see {Event::Tokens}), in absolute tokens: a
      # host that knows the model's cap ({Agent::ChatTransport#context_window}) shows
      # it beside. +Δ+ is the signed climb between turns
      # (equal to +ctx+ on msg #1); +↑+/+↓+ are this turn's input/output
      # (Claude Code's convention). Sizes are 1024-scaled with a +k+ suffix.
      #
      # One instance per conversation (the snapshot is instance state);
      # sub-agents get a fresh zeroed one via {#for_sub_agent}.
      class TokenLog < Base
        # Subsystem logger; the per-turn line is +INFO+. Level via
        # +PIKURI_LOG_TOKENS+ or +PIKURI_LOG+.
        #
        # @return [Logger]
        LOGGER = Pikuri.logger_for('Tokens')

        # Tokens consumed by the conversation through the most recent turn
        # (+input + cached + cache_creation + output+ from the latest
        # {Event::Tokens}). Zero until the first arrives.
        #
        # @return [Integer]
        attr_reader :context_window_size

        # @return [String] owning agent's id ({Agent#id}); empty for the main
        #   agent, set by {#for_sub_agent} so log lines get an +[<id>] + prefix.
        attr_reader :id

        # The most recent status line, *without* the +[<id>] + prefix (the
        # prefix is {LOGGER}'s concern; consumers get the id separately via
        # {#id} / {#on_status_line} and choose their own presentation). Empty
        # until the first {Event::Tokens}. Hosts surfacing the snapshot in
        # their own UI (a TUI footer) read this; hosts wanting to be pushed set
        # {#on_status_line}.
        #
        # Safe to read from any thread (a single +String+ ivar read); a reader
        # may briefly see the previous turn's line mid-{#on_event}, acceptable
        # for a status display.
        #
        # @return [String]
        attr_reader :status_line

        # Optional status-line observer, +nil+ by default. When callable, it's
        # invoked with the owning agent's {#id} and the freshly formatted
        # {#status_line} after every {Event::Tokens} — the push counterpart to
        # polling {#status_line}. Fires on the agent's loop thread, so the
        # callable must hand off to its sink thread-safely; it sits on the
        # loop's path, so an exception it raises propagates into the
        # conversation (handle dead connections inside it).
        #
        # {#for_sub_agent} copies the observer by reference, so one callable
        # receives parent and sub-agent lines alike — the +id+ parameter routes
        # each to the right row. An observer assigned *after* a sub-agent
        # spawned doesn't reach that sub-agent's instance.
        #
        # @return [Proc, nil] called with +(id, status_line)+ — the agent's id
        #   and the unprefixed {#status_line}
        attr_accessor :on_status_line

        # @param id [String] owning agent's id, prepended to each
        #   log line as +[<id>] + when non-empty. Defaults to +""+
        #   for the main agent.
        def initialize(id: '')
          super()
          @id = id
          @msg = 0
          @context_window_size = 0
          @status_line = ''
          @on_status_line = nil
        end

        # Sub-agent variant: a fresh +TokenLog+ with a zeroed snapshot so the
        # sub-agent tracks its own +RubyLLM::Chat+, carrying the sub-agent's
        # +id:+ (for the +[<id>] + prefix) and the {#on_status_line} observer
        # by reference.
        #
        # @param id [String] sub-agent's id
        # @return [TokenLog]
        def for_sub_agent(id: '', **)
          derived = self.class.new(id: id)
          derived.on_status_line = @on_status_line
          derived
        end

        # @param event [Agent::Event]
        # @return [void]
        def on_event(event)
          case event
          in Event::Tokens => tokens
            log_tokens(tokens)
          in Event::HistoryLoaded(tokens:)
            seed_snapshot(tokens)
          else
            # Every other variant: no-op.
          end
        end

        # @return [String] short label for {ListenerList#to_s}, including
        #   the current context-window size
        def to_s
          "TokenLog(ctx=#{format_k(@context_window_size)})"
        end

        private

        # Restore the running size from a conversation just loaded off disk
        # ({Event::HistoryLoaded}). Without this the footer reads +0.0k+
        # against 40k of restored history until the next reply corrects it.
        #
        # The message counter deliberately stays at zero: it counts replies
        # *this* session, and restored turns did not happen here. A history
        # exported without usage (+tokens+ +nil+) leaves the zeroed snapshot
        # alone rather than inventing a number.
        #
        # @param tokens [Event::Tokens, nil] usage of the last restored
        #   assistant message.
        # @return [void]
        def seed_snapshot(tokens)
          return if tokens.nil?

          @context_window_size = tokens.input.to_i + tokens.cached.to_i +
                                 tokens.cache_creation.to_i + tokens.output.to_i
          @status_line = "restored: ctx=#{format_k(@context_window_size)}"
          @on_status_line&.call(@id, @status_line)
          nil
        end

        # Update the snapshot, write one +INFO+ line to the
        # subsystem logger, and push the line to the status-line
        # observer (when one was given at construction).
        #
        # @param tokens [Event::Tokens]
        # @return [void]
        def log_tokens(tokens)
          @msg += 1
          input_now          = tokens.input.to_i
          cached_now         = tokens.cached.to_i
          cache_creation_now = tokens.cache_creation.to_i

          prev_ctx = @context_window_size
          @context_window_size = input_now + cached_now + cache_creation_now + tokens.output.to_i
          delta = @context_window_size - prev_ctx

          @status_line = format_line(input_now, tokens.output.to_i, delta)
          prefix = @id.empty? ? '' : "[#{@id}] "
          LOGGER.info("#{prefix}#{@status_line}")
          @on_status_line&.call(@id, @status_line)
        end

        def format_line(input, output, delta)
          sign = delta.negative? ? '-' : '+'
          "msg ##{@msg}: ctx=#{format_k(@context_window_size)}  Δ#{sign}#{format_k(delta.abs)}  ↑#{format_k(input)}  ↓#{format_k(output)}"
        end

        # Format a token count as a 1024-scaled +k+-suffixed string
        # (+nil+/+0+ → +0.0k+, 12_453 → +12.2k+).
        #
        # @param n [Integer, nil]
        # @return [String]
        def format_k(n)
          format('%.1fk', n.to_i / 1024.0)
        end
      end
    end
  end
end
