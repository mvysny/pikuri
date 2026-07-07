# frozen_string_literal: true

require 'rainbow'
require 'reline'
require 'tmpdir'

module Pikuri
  module Workspace
    # Port for asking the user to confirm a potentially destructive tool
    # operation — currently {Pikuri::Code::Bash} (every command), {Write}
    # (overwrite of an existing file with non-identical content) and the
    # +agent+ tool's delegation gate. Subclass and implement {#decide}.
    #
    # == The return type: {Approved} / {Rejected}
    #
    # {#decide} returns one of exactly two value types — {Approved}
    # (carrying the possibly-edited {Request#detail} to act on) or
    # {Rejected} (carrying an optional human decline reason). Callers
    # dispatch by pattern-matching:
    #
    #   case confirmer.decide(request: request)
    #   in Confirmer::Approved(new_request_detail:) then ...act on it...
    #   in Confirmer::Rejected(reason:)             then ...steer with it...
    #   end
    #
    # {#confirm?} is the derived boolean convenience for the mutation
    # gates ({Write}, {Pikuri::Code::ExitPlanMode}) that need neither the
    # edited payload nor the reason.
    #
    # This richer return carries two orthogonal axes:
    #
    # 1. *Editing (opt-in per request via {Request#editable}).* When the
    #    detail is the verbatim actionable payload — the +agent+ tool's
    #    task string, where +detail == task+ — a confirmer may let the
    #    human *rewrite* it rather than rubber-stamp it: the "human as
    #    author, not approver" shape (see +ideas/more-confirmers.md+ and
    #    +ideas/private-context-taint.md+). Bash's +"$ <command>"+ is a
    #    decorated display string, not a verbatim payload, so it stays
    #    non-editable.
    # 2. *Reason (universal).* Any decline can carry the human's typed
    #    steering ("use the other library") back to the model as the next
    #    observation, turning a bare rejection into direction.
    #
    # The path *not* taken, worth recording so the design space is
    # legible: a +:once+ / +:always+ scope knob. That is a distinct axis —
    # it manages *decision fatigue*, not *authorship or steering* — and it
    # was rejected because the long-term answer to fatigue is making
    # confirmations rare (sandboxing, +--yolo+), not smarter approval
    # modes. The edit/reason axes added here do not reopen it. (An agentic
    # destructive-or-not classifier remains a deferred v2.)
    #
    # == Seam discipline
    #
    # Tools that need confirmation take a {Confirmer} via constructor and
    # invoke {#decide} with a semantic {Request} — *what* is being asked,
    # never *how* it should look. All presentation belongs to the
    # confirmer implementation: color, the answer cue, answer parsing, the
    # edit affordance, and — security-relevant — neutralizing hostile
    # bytes in LLM-supplied text. The chrome-independent half of that
    # (escape control bytes, flag bidi / zero-width / homoglyph spoofs) is
    # the shared {Pikuri::Sanitizer}; the medium-specific half stays with
    # the renderer that knows its medium (a terminal prints the sanitized
    # text directly; a web client wraps it in HTML-escaping). Tools do
    # *not* call +gets+ / +puts+ directly — same lesson as listeners, keep
    # IO at the seam so a TUI / web client can plug a different
    # implementation in without touching tool code.
    class Confirmer
      # The semantic payload of one confirmation. Three fields:
      #
      # * +question+ — one-line headline composed by the calling tool,
      #   e.g. +"OK to overwrite foo.rb: 120 → 245 bytes?"+. The caller
      #   owns the phrasing and punctuation; the renderer owns the
      #   answer cue (+"(y/n)?"+, buttons, ...).
      # * +detail+ — optional preformatted body, possibly multi-line:
      #   the raw bash command for {Pikuri::Code::Bash}, the task string
      #   for the +agent+ tool, +nil+ for {Write}. Renderers typically
      #   display it monospaced / dimmed. When +editable+ is true this is
      #   the exact text the human may rewrite, and the edited value comes
      #   back as {Approved#new_request_detail}.
      # * +editable+ — whether the human may *edit* +detail+ before
      #   approving (default +false+). Set +true+ only when +detail+ is
      #   the verbatim actionable payload (the +agent+ task), never for a
      #   decorated display string (bash's +"$ <command>"+).
      #
      # +question+ and +detail+ are RAW, straight from tool arguments the
      # LLM composed. Renderers MUST neutralize them before display —
      # route through {Pikuri::Sanitizer} (see {Terminal}), and
      # additionally HTML-escape in a web client.
      Request = Data.define(:question, :detail, :editable, :change) do
        # @param question [String] one-line headline; caller owns phrasing
        # @param detail [String, nil] optional preformatted body / editable payload
        # @param editable [Boolean] whether the human may rewrite +detail+
        # @param change [Change, nil] optional structured file change; when
        #   present a diff-capable chrome renders a diff of it (see {Change}).
        def initialize(question:, detail: nil, editable: false, change: nil)
          super
        end
      end

      # A structured file change for a {Write} / {Edit} confirmation. The
      # tool hands over the *semantic* change — path + old bytes + new
      # bytes — rather than a pre-rendered string, so that rendering the
      # diff stays the confirmer's job (the Confirmer seam: presentation
      # belongs to the chrome). {Terminal} renders a unified diff by
      # shelling to +diff+ (the educational chrome's differ); a richer
      # client (pikuri-tui) renders the same {Change} with its own diff
      # library. +old+ is the current file bytes, or +nil+ for a new file.
      Change = Data.define(:path, :old, :new)

      # An approval. Carries the text to act on: the human-authored
      # (possibly edited) form of {Request#detail} when the request was
      # editable, or +detail+ verbatim otherwise.
      Approved = Data.define(:new_request_detail)

      # A decline. Carries the human's optional steering reason (+nil+
      # when none was given), which the calling tool folds into the
      # observation it hands back to the model.
      Rejected = Data.define(:reason)

      # @param request [Request] semantic content composed by the calling
      #   tool. The confirmer renders it (escaping for its medium), poses
      #   the question, and parses the answer.
      # @return [Approved, Rejected]
      # @raise [NotImplementedError] in the abstract base
      def decide(request:)
        raise NotImplementedError, "#{self.class}#decide must be implemented"
      end

      # Boolean convenience over {#decide} for mutation gates that need
      # neither the edited payload nor the decline reason.
      #
      # @param request [Request]
      # @return [Boolean] +true+ iff approved
      def confirm?(request:)
        decide(request:).is_a?(Approved)
      end

      # Stdin/stdout implementation. Renders the request as up to several
      # lines (a leading +puts+ guarantees separation from any streamed
      # output the +Terminal+ listener may have produced just above):
      #
      # 1. a bold-yellow warning block — one line per
      #    {Pikuri::Sanitizer::Warning} — shown only when the sanitizer
      #    flagged something suspicious in the question or detail
      # 2. the question, bold
      # 3. the detail, dim — omitted when +nil+
      # 4. the answer cue
      #
      # Both question and detail pass through {Pikuri::Sanitizer}, which
      # neutralizes control bytes — without it, a model could craft a
      # command or description containing +"\rrm -rf ~/"+ that visually
      # overwrites the echoed line after the user has already read it —
      # and reports *why* it was unsafe so the user reads the warning
      # before answering. Colors come from Rainbow (already in the
      # dependency closure via pikuri-core), which self-disables on
      # non-TTY output.
      #
      # == The two flows
      #
      # A *non-editable* request (bash, write) gets the classic +(y/n)?+
      # cue: +y+/+yes+ → {Approved}, +n+/+no+ → {Rejected} (after an
      # optional reason prompt), EOF → {Rejected} with no reason, anything
      # else re-prompts.
      #
      # An *editable* request (the +agent+ task) additionally offers +e+
      # to edit. Here the sanitizer warning set gates the pre-fill: the
      # payload sent onward must be RAW bytes, but the terminal must
      # *display* sanitized bytes — so pre-filling an editable buffer with
      # raw bytes would reintroduce the very control-byte attack the
      # sanitizer defends against. Therefore:
      #
      # * *clean* task (no warnings) — offer +[y] approve  [e] edit
      #   [n] reject+; +e+ opens the raw task in a Reline-editable buffer.
      # * *flagged* task (warnings present) — refuse the pre-fill and drop
      #   the bare-approve path: +[e] edit  [n] reject+, where +e+ makes
      #   the human retype from scratch. Forced authorship exactly where
      #   it matters most.
      #
      # Honest limit: a terminal cannot *structurally* forbid a
      # rubber-stamp +y+ on a clean task — the pure no-rubber-stamp author
      # seat is a richer-UI (web) invariant. The warning-gated
      # forced-retype is the terminal's partial answer.
      class Terminal < Confirmer
        LOGGER = Pikuri.logger_for('Workspace::Confirmer')

        # Maximum diff lines rendered before truncation — keeps a
        # whole-file rewrite from scrolling the terminal off-screen.
        DIFF_MAX_LINES = 300

        # @param request [Request]
        # @return [Approved, Rejected]
        def decide(request:)
          warnings = render(request)
          if request.editable && !request.detail.nil?
            decide_editable(request, clean: warnings.empty?)
          else
            decide_plain(request)
          end
        end

        private

        # Print the sanitized question / detail / warning block.
        #
        # @param request [Request]
        # @return [Array<Pikuri::Sanitizer::Warning>] the flagged warnings
        #   (empty when clean) — the caller gates the edit pre-fill on this.
        def render(request)
          question = Pikuri::Sanitizer.sanitize(request.question)
          detail   = request.detail ? Pikuri::Sanitizer.sanitize(request.detail) : nil
          raw_diff = request.change ? unified_diff(request.change) : nil
          diff     = raw_diff ? Pikuri::Sanitizer.sanitize(raw_diff) : nil
          warnings = question.warnings + (detail ? detail.warnings : []) + (diff ? diff.warnings : [])

          puts
          unless warnings.empty?
            puts Rainbow('⚠ Suspicious content detected — read carefully before approving:').yellow.bold
            warnings.each { |w| puts Rainbow("  ! #{w.explanation}").yellow }
          end
          puts Rainbow(question.text).bold
          puts Rainbow(detail.text).dimgray if detail
          print_diff(diff.text) if diff
          warnings
        end

        # Render a unified diff of +change+ by shelling to +diff -u+ (the
        # educational chrome's differ, routed through the {Pikuri::Subprocess}
        # chokepoint; a richer client renders the same {Change} with its own
        # diff library). Old/new bytes go to tempfiles under a
        # self-cleaning dir. Returns the diff text, capped at
        # {DIFF_MAX_LINES}, or +nil+ on any failure (empty diff, missing
        # +diff+, IO error) — a cosmetic path secondary to the confirm, so
        # it degrades to "no diff shown" rather than raising.
        #
        # @param change [Change]
        # @return [String, nil]
        def unified_diff(change)
          Dir.mktmpdir('pikuri-diff-') do |dir|
            old_f = File.join(dir, 'old')
            new_f = File.join(dir, 'new')
            out_f = File.join(dir, 'out')
            File.binwrite(old_f, change.old || '')
            File.binwrite(new_f, change.new)
            File.open(out_f, 'w') do |o|
              Pikuri::Subprocess.run(
                'diff', '-u', '--label', "a/#{change.path}", '--label', "b/#{change.path}",
                old_f, new_f, stdin_data: '', stdout: o, chdir: dir
              )
            end
            text = File.read(out_f)
            return nil if text.empty?

            lines = text.lines
            return text if lines.size <= DIFF_MAX_LINES

            lines.first(DIFF_MAX_LINES).join + "… (#{lines.size - DIFF_MAX_LINES} more diff lines)\n"
          end
        rescue StandardError => e
          LOGGER.warn("diff render failed (#{e.class}: #{e.message}); confirming without a diff")
          nil
        end

        # Print a sanitized unified diff, coloring +added+ / -removed /
        # @@hunk@@ lines. Sanitization already ran in {#render}; this only
        # adds medium-specific color (Rainbow self-disables on non-TTY).
        #
        # @param text [String] sanitized diff text
        # @return [void]
        def print_diff(text)
          text.each_line do |line|
            body = line.chomp
            puts(case body[0]
                 when '+' then Rainbow(body).green
                 when '-' then Rainbow(body).red
                 when '@' then Rainbow(body).cyan
                 else Rainbow(body).dimgray
                 end)
          end
        end

        # The classic +(y/n)?+ flow, now returning {Approved} / {Rejected}
        # and prompting for a decline reason on +n+.
        #
        # @param request [Request]
        # @return [Approved, Rejected]
        def decide_plain(request)
          puts '(y/n)?'
          $stdout.flush
          loop do
            line = $stdin.gets
            return Rejected.new(reason: nil) if line.nil?

            answer = line.strip.downcase
            return Approved.new(new_request_detail: request.detail) if answer == 'y' || answer == 'yes'
            return Rejected.new(reason: read_reason) if answer == 'n' || answer == 'no'

            print 'Please answer y or n: '
            $stdout.flush
          end
        end

        # The editable flow: approve-as-is (clean only), edit, or reject.
        #
        # @param request [Request]
        # @param clean [Boolean] whether the payload passed the sanitizer
        #   (gates the pre-fill and the bare-approve path)
        # @return [Approved, Rejected]
        def decide_editable(request, clean:)
          puts(clean ? '[y] approve  [e] edit  [n] reject' : '⚠ retype required — [e] edit  [n] reject')
          $stdout.flush
          loop do
            line = $stdin.gets
            return Rejected.new(reason: nil) if line.nil?

            answer = line.strip.downcase
            if clean && (answer == 'y' || answer == 'yes')
              return Approved.new(new_request_detail: request.detail)
            end
            if answer == 'e' || answer == 'edit'
              return Approved.new(new_request_detail: read_edited(initial: request.detail, prefill: clean))
            end
            return Rejected.new(reason: read_reason) if answer == 'n' || answer == 'no'

            print(clean ? 'Please answer y, e, or n: ' : 'Please answer e or n: ')
            $stdout.flush
          end
        end

        # Read the human's (re)authored task.
        #
        # @param initial [String] the raw payload to pre-fill with
        # @param prefill [Boolean] when +true+ the initial text is placed
        #   in the editable buffer (clean payloads only); when +false+ the
        #   human types a fresh line — the forced retype for flagged input,
        #   which never puts raw bytes on the terminal.
        # @return [String] the edited text (may be empty if the human cleared it)
        def read_edited(initial:, prefill:)
          if prefill
            Reline.pre_input_hook = lambda do
              Reline.insert_text(initial)
              Reline.pre_input_hook = nil
            end
          end
          (Reline.readline('task> ', false) || '').chomp
        ensure
          Reline.pre_input_hook = nil
        end

        # Prompt for an optional decline reason (steering text handed back
        # to the model as the next observation).
        #
        # @return [String, nil] the trimmed reason, or +nil+ for blank / EOF
        def read_reason
          print 'Reason (optional, Enter to skip): '
          $stdout.flush
          line = $stdin.gets
          return nil if line.nil?

          reason = line.strip
          reason.empty? ? nil : reason
        end
      end

      # Approves everything unedited. Used by +bin/pikuri-code --yolo+
      # (docker / dev-container mode) and by tool specs that don't want to
      # coordinate stdin. The name +AutoApprove+ matches the public
      # constant {AUTO_APPROVE}.
      class AutoApprove < Confirmer
        # @param request [Request]
        # @return [Approved] always, carrying +detail+ unchanged
        def decide(request:)
          Approved.new(new_request_detail: request.detail)
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
