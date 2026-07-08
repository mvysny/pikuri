# frozen_string_literal: true

require 'rainbow'
require 'reline'
require 'tmpdir'

module Pikuri
  module Workspace
    class Confirmer
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
      # This is the human *chrome* — the one confirmer that renders a
      # dialog and reads an answer. It lives in its own file (this one)
      # rather than in +confirmer.rb+ so the base seam file carries no
      # rendering dependencies (Rainbow / Reline / tmpdir ride only here).
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
    end
  end
end
