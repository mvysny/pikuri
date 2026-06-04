# frozen_string_literal: true

require 'rainbow'

module Pikuri
  module Workspace
    # Port for asking the user to confirm a potentially destructive tool
    # operation — currently {Pikuri::Code::Bash} (every command) and
    # {Write} (overwrite of an existing file with non-identical
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
    # invoke {#confirm?} with a semantic {Request} — *what* is being
    # asked, never *how* it should look. All presentation belongs to the
    # confirmer implementation: color, the answer cue, answer parsing,
    # and — security-relevant — escaping of hostile bytes in
    # LLM-supplied text. Escaping is medium-specific (a terminal must
    # neutralize +\r+ / ESC so the model can't visually overwrite the
    # echoed command; a web client must HTML-escape instead), so it can
    # only live with the renderer that knows its medium. Tools do *not*
    # call +gets+ / +puts+ directly — same lesson as listeners, keep IO
    # at the seam so a TUI / web client can plug a different
    # implementation in without touching tool code.
    class Confirmer
      # The semantic payload of one confirmation. Two fields:
      #
      # * +question+ — one-line headline composed by the calling tool,
      #   e.g. +"OK to overwrite foo.rb: 120 → 245 bytes?"+. The caller
      #   owns the phrasing and punctuation; the renderer owns the
      #   answer cue (+"(y/n)?"+, buttons, ...).
      # * +detail+ — optional preformatted body, possibly multi-line:
      #   the raw bash command for {Pikuri::Code::Bash}, +nil+ for
      #   {Write}. Renderers typically display it monospaced / dimmed.
      #
      # Both fields are RAW, straight from tool arguments the LLM
      # composed (+detail+ is the command verbatim; +question+ may embed
      # an LLM-written description). Renderers MUST escape them for
      # their medium before display — see {Terminal} for the
      # control-byte treatment, and use HTML-escaping in a web client.
      Request = Data.define(:question, :detail) do
        # @param question [String] one-line headline; caller owns phrasing
        # @param detail [String, nil] optional preformatted body
        def initialize(question:, detail: nil)
          super
        end
      end

      # @param request [Request] semantic content composed by the
      #   calling tool. The confirmer renders it (escaping for its
      #   medium), poses the question, and parses the answer.
      # @return [Boolean] +true+ iff approved
      # @raise [NotImplementedError] in the abstract base
      def confirm?(request:)
        raise NotImplementedError, "#{self.class}#confirm? must be implemented"
      end

      # Stdin/stdout implementation. Renders the request as up to three
      # lines (a leading +puts+ guarantees separation from any streamed
      # output the +Terminal+ listener may have produced just above):
      #
      # 1. the question, bold
      # 2. the detail, dim — omitted when +nil+
      # 3. the +(y/n)?+ cue
      #
      # Both question and detail pass through {#visible}, which escapes
      # control bytes — without it, a model could craft a command or
      # description containing +"\rrm -rf ~/"+ that visually overwrites
      # the echoed line after the user has already read it. Colors come
      # from Rainbow (already in the dependency closure via pikuri-core),
      # which self-disables on non-TTY output.
      #
      # Then reads one line from +$stdin+ and parses it strictly:
      #
      # * +"y"+ / +"yes"+ (case-insensitive, stripped) → +true+
      # * +"n"+ / +"no"+ → +false+
      # * EOF / Ctrl+D (+gets+ returns +nil+) → +false+, deliberate abort
      # * anything else (blank, typo, +"maybe"+) → re-prompt with a short
      #   "Please answer y or n: " line and loop
      #
      # No retry cap; EOF eventually breaks adversarial input.
      class Terminal < Confirmer
        # @param request [Request]
        # @return [Boolean]
        def confirm?(request:)
          puts
          puts Rainbow(visible(request.question)).bold
          puts Rainbow(visible(request.detail)).dimgray if request.detail
          puts '(y/n)?'
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

        private

        # Escape control bytes for safe terminal display while
        # preserving +\n+ (multi-line shell commands are normal).
        # Catches +\r+, +\x1b+ (ESC, the ANSI introducer), +\b+, NUL,
        # DEL, etc. Same treatment as +Pikuri::Code::Bash.visible+,
        # which guards the *observation* echo on the other side of the
        # seam — keep the two in sync.
        #
        # @param text [String]
        # @return [String]
        def visible(text)
          text.gsub(/[\x00-\x09\x0b-\x1f\x7f]/) { |c| format('\\x%02x', c.ord) }
        end
      end

      # Approves everything. Used by +bin/pikuri-code --yolo+ (docker /
      # dev-container mode) and by tool specs that don't want to
      # coordinate stdin. The name +AUTO_APPROVE+ matches the public
      # constant {AUTO_APPROVE}.
      class AutoApprove < Confirmer
        # @param request [Request] ignored
        # @return [true]
        def confirm?(request:)
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
