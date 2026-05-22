# frozen_string_literal: true

module Pikuri
  class Tool
    # Port for asking the user to confirm a potentially destructive tool
    # operation — currently {Tool::Bash} (every command) and
    # {Tool::Write} (overwrite of an existing file with non-identical
    # content). Subclass and implement {#confirm?}.
    #
    # == Why a Boolean return
    #
    # v1 returns +true+ or +false+. Two paths-not-taken worth recording
    # so a future reader knows the design space was considered:
    #
    # 1. Richer return (+:once+ / +:always+ / +:reject+) — rejected
    #    because it creates decision fatigue, and the long-term answer
    #    is to make confirmations rare rather than smart (sandboxing,
    #    agentic destructiveness analysis).
    # 2. Agentic destructive-or-not classifier — deferred to v2.
    #
    # The intended escape from confirmation prompts today is sandboxing
    # (docker / dev-container) plus the +--yolo+ flag on +bin/pikuri-code+
    # (which wires {AUTO_APPROVE} instead of {TERMINAL}).
    #
    # == Seam discipline
    #
    # Tools that need confirmation take a {Confirmer} via constructor and
    # invoke {#confirm?} with a fully-composed prompt String. Tools do
    # *not* call +gets+ / +puts+ directly — same lesson as listeners,
    # keep IO at the seam so a future TUI / web client can plug a
    # different implementation in without touching tool code.
    class Confirmer
      # @param prompt [String] human-readable question composed by the
      #   calling tool. The confirmer renders it and parses the answer;
      #   it does NOT compose its own prompt content. Caller owns the
      #   closing punctuation and any "(y/n)" cue.
      # @return [Boolean] +true+ iff approved
      # @raise [NotImplementedError] in the abstract base
      def confirm?(prompt:)
        raise NotImplementedError, "#{self.class}#confirm? must be implemented"
      end

      # Stdin/stdout implementation: prints +prompt+ on its own line (a
      # leading +puts+ guarantees separation from any streamed output
      # the +Terminal+ listener may have produced just above), reads one
      # line from +$stdin+, parses it strictly:
      #
      # * +"y"+ / +"yes"+ (case-insensitive, stripped) → +true+
      # * +"n"+ / +"no"+ → +false+
      # * EOF / Ctrl+D (+gets+ returns +nil+) → +false+, deliberate abort
      # * anything else (blank, typo, +"maybe"+) → re-prompt with a short
      #   "Please answer y or n: " line and loop
      #
      # No retry cap; EOF eventually breaks adversarial input.
      class Terminal < Confirmer
        # @param prompt [String]
        # @return [Boolean]
        def confirm?(prompt:)
          puts
          puts prompt
          $stdout.flush
          loop do
            line = $stdin.gets
            return false if line.nil?

            answer = line.strip.downcase
            return true  if answer == 'y' || answer == 'yes'
            return false if answer == 'n' || answer == 'no'

            print 'Please answer y or n: '
            $stdout.flush
          end
        end
      end

      # Approves everything. Used by +bin/pikuri-code --yolo+ (docker /
      # dev-container mode) and by tool specs that don't want to
      # coordinate stdin. The name +AUTO_APPROVE+ matches the public
      # constant {AUTO_APPROVE}.
      class AutoApprove < Confirmer
        # @param prompt [String] ignored
        # @return [true]
        def confirm?(prompt:)
          true
        end
      end

      # Shared singleton instance of {Terminal}. Stateless; reusable
      # across tools and sub-agents.
      TERMINAL = Terminal.new

      # Shared singleton instance of {AutoApprove}.
      AUTO_APPROVE = AutoApprove.new
    end
  end
end
