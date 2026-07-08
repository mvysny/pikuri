# frozen_string_literal: true

require 'set'

module Pikuri
  module Code
    class Bash
      # A deliberately narrow shell tokenizer: it turns a command string
      # into one word list per *sequencer segment*, or returns +nil+ when
      # it cannot prove the command is such a simple chain. It makes **no
      # read-only judgement** — that policy lives in its caller
      # ({ReadOnlyCommandApprover}, which classifies the word lists this
      # produces). The split here is between *lexing* (this class) and
      # *authorization* (the approver), so a second consumer could reuse
      # the same parse.
      #
      # {.tokenize} either returns +Array<Array<String>>+ — segments
      # (cut on {SEQUENCERS}) of de-quoted, de-redirected words, an empty
      # list marking a pure-comment no-op segment — or +nil+, meaning
      # "more than a simple chain of bare invocations" (a metacharacter, an
      # unsafe redirect, an unbalanced quote, too many segments). The
      # contract is conservative: when in doubt it returns +nil+ so the
      # caller delegates to a human; it never silently drops a dangerous
      # byte.
      #
      # == Why splitting on the sequencers is faithful
      #
      # {.split_segments} cuts the command only on a genuine control
      # operator, never one hidden inside a string: it tracks quote state
      # (single *and* double) and refuses to split inside a quoted span,
      # and the backslash stays forbidden ({SHELL_METACHARACTERS} outside
      # quotes, {DQUOTE_LIVE} inside double quotes), so nothing can escape
      # a +;+, +|+ or newline past it. Every *other*
      # metacharacter stays forbidden per segment, so an arbitrary-target
      # redirect (+ps | grep x > out+), a background +&+ (+ls & pwd+ — +&+
      # is not a sequencer) or +|&+ all trip the metacharacter check ⇒
      # +nil+. The lone exception is a write-nothing redirect fragment
      # ({SAFE_REDIRECT}: +2>&1+, +2>/dev/null+ …), consumed and dropped
      # during the scan — fd duplication and +/dev/null+ discards add no
      # capability.
      #
      # == Single quotes: real quote-removal, not a placeholder rewrite
      #
      # A single-quoted argument is common and harmless (+grep -w
      # 'install'+, +grep 'foo bar' f+), so {.scan_segment} decodes it.
      # POSIX single quotes are the *only* quoting form safe to decode:
      # the interior is purely literal — no escapes, no expansion, closed
      # by the next +'+ — so a quoted span can contribute nothing to
      # command *structure*. The scan performs genuine shell quote-removal:
      # the +'+ marks are dropped and the interior is appended to the
      # current word *verbatim*, interior bytes never treated as separators
      # or metacharacters (so +echo 'a | b'+ is one segment, one echo). An
      # unbalanced +'+ returns +nil+; a quoted command name decodes to a
      # word the caller's allowlist won't match (+'rm'+ → +rm+).
      #
      # The subtlety — and why a cheap +gsub+ would be *unsafe* — is for a
      # caller that matches flags by *spelling*. A rewrite that blanks
      # +'...'+ to a placeholder (+--''clear+ → +--_clear+) diverges from
      # real quote-removal and smuggles an analyzer-only byte into the
      # middle of a flag, so a +dmesg+ denylist / git +--output+ check
      # would miss the mutating flag while the shell still runs +--clear+ /
      # +--output+. Real quote-removal collapses +--''clear+ to the true
      # +--clear+. The asymmetry to keep in mind: an *exact-match
      # allowlist* (a binary name, a verb) fails *safe* under quote
      # injection — the match just breaks; a *denylist / prefix* check
      # fails *open* unless it sees the genuinely de-quoted word. This
      # tokenizer hands back that genuine word, so both kinds are sound.
      #
      # == Double quotes: decoded only when verifiably inert
      #
      # POSIX keeps exactly three characters live inside +"..."+: +$+
      # (every expansion form), the backtick (command substitution) and
      # +\+ (escaping — also the only way to move the closing +"+).
      # Everything else — +|+, +;+, +*+, +?+, +#+, +~+, whitespace — is
      # literal there, with no word splitting or globbing. So a
      # double-quoted span containing none of the three ({DQUOTE_LIVE}) is
      # semantically identical to a single-quoted one, and {.scan_segment}
      # decodes it by the same real quote-removal; a span containing any
      # of them returns +nil+ — delegate, never guess. Single quotes are
      # decoded because their interior is *unconditionally* literal;
      # double quotes only when it is *verifiably* literal. This admits
      # the common LLM shape +echo " bytes"+ / +grep "foo bar" f+ while
      # keeping the failure mode "asks the human too often".
      #
      # The classic mis-parse — +echo "a\"b; rm x"+, where a naive lexer
      # closes the span at the escaped quote and exposes the +;+ — cannot
      # happen here: the left-to-right scan bails on the +\+ *before* ever
      # reaching the quote it escapes, so a span end is never mis-located.
      # ({.split_segments}'s simpler tracker does close a span at an
      # escaped quote, but any command where that matters contains a +\+
      # outside single quotes, every byte lands in *some* segment, and
      # {.scan_segment} rejects that segment — so the divergence can only
      # produce +nil+, never a mis-parsed approval.)
      #
      # Bash's fourth live character, +!+ (history expansion), is
      # deliberately NOT gated inside the span: it fires only in
      # interactive shells, and {Bash} always spawns +bash -c+ —
      # non-interactive, histexpand off — so +echo "done!"+ is literal in
      # every shell this verdict reaches (the same wiring-fact argument as
      # the confirmer's systemctl-pager reasoning). Outside quotes +!+
      # stays forbidden as before.
      module Tokenizer
        # Any shell metacharacter or ASCII control byte that, encountered
        # *outside* a quoted span, means the segment is more than a
        # single simple invocation (or is hiding something) — so it
        # returns +nil+. {.scan_segment} consults this per character only
        # after handling quotes, whitespace and the {SAFE_REDIRECT}
        # forms, so the +>+/+&+ of a safe redirect and every byte inside a
        # quoted argument never reach it.
        #
        # The backslash +\+ stays here (still forbidden): it escapes, so
        # decoding it would reopen the parsing surface the quote handling
        # deliberately avoids. The double quote is *not* listed — like
        # +'+, it is handled by {.scan_segment}'s quote branches before
        # this gate is consulted (decoded when inert, +nil+ the moment a
        # {DQUOTE_LIVE} byte appears inside). Note +=+ is *not* here
        # (+--color=never+); a leading +VAR=val+ is caught anyway because
        # the first word then isn't a bare allowed binary.
        SHELL_METACHARACTERS = /[;&|<>$`()\\!#*?\[\]{}~\x00-\x1f]/

        # The three characters POSIX keeps live inside a double-quoted
        # span — +$+ (parameter / command / arithmetic expansion), the
        # backtick (command substitution) and +\+ (escaping, including of
        # the closing +"+). {.scan_segment} returns +nil+ when any of them
        # appears inside +"..."+; every other interior byte is literal and
        # is appended verbatim, exactly as in a single-quoted span. See
        # the class header for why +!+ (interactive-only history
        # expansion) is deliberately not gated.
        DQUOTE_LIVE = /[$`\\]/

        # Shell control operators that merely *sequence or pipe* commands.
        # {.split_segments} cuts the command on these — but only outside
        # quotes, so a quoted +|+/+;+ is literal data
        # (+echo 'a | b'+ is one segment). Alternation order matters: the
        # two-char +&&+ / +||+ must be tried before the single +|+ so
        # +a || b+ splits into two segments, not three.
        #
        # A newline is included because it is a command *terminator*
        # exactly like +;+ — a multi-line script is a sequence of
        # commands. (A newline meant literally would have to sit inside a
        # quoted span, where {.split_segments} treats it as data.)
        SEQUENCERS = /&&|\|\||;|\||\n/

        # Defensive ceiling on the number of sequencer-joined segments.
        # The split and per-segment checks are linear and cheap, so this
        # is only a sanity backstop against pathological input, set high
        # enough to clear a real generated batch (e.g. a +dpkg -S … || true+
        # probe per unit file across dozens of files); beyond it the whole
        # command simply returns +nil+ rather than being analyzed.
        MAX_CHAIN = 64

        # A redirect fragment that writes nothing to the filesystem.
        # {.scan_segment} anchors this at a +>+ (or +&>+) it meets and, on
        # a match, consumes and drops it (so the +>+/+&+ never reaches the
        # {SHELL_METACHARACTERS} gate); a +>+ that does *not* match here is
        # a real redirect and returns +nil+. Two safe families only:
        #
        # * file-descriptor *duplication* — +[n]>&[m]+ (+2>&1+ merges
        #   stderr into stdout, +1>&2+ the reverse): pure in-process
        #   fd-table manipulation, never a file.
        # * *discard* to +/dev/null+ — +[n|&]>[>] /dev/null+
        #   (+2>/dev/null+, +> /dev/null+, +&>/dev/null+, append forms):
        #   the kernel bit bucket.
        #
        # The discard target is pinned to *exactly* +/dev/null+ by the
        # +(?=\s|\z)+ lookahead, so a look-alike write target
        # (+2>/dev/nullx+, +2>/dev/null.bak+) does not match ⇒ the +>+
        # returns +nil+ — as does any arbitrary-file redirect
        # (+2>/etc/passwd+, +> out+). +\s*+ accepts the operator and target
        # either glued (+2>/dev/null+) or spaced (+> /dev/null+). The
        # leading +[0-9]*+ is the fd that {.scan_segment} has accumulated
        # into the current word (the +2+ of +2>&1+); it trims those digits
        # back off when the match succeeds.
        SAFE_REDIRECT = %r{[0-9]*>&[0-9]+|(?:[0-9]|&)?>>?\s*/dev/null(?=\s|\z)}

        class << self
          # Parse the command into one word list per {SEQUENCERS} segment,
          # or +nil+ if it cannot be safely analyzed as such a chain.
          #
          # {.split_segments} cuts the command on the sequencers
          # (quote-awarely) and {.scan_segment} reduces each segment to its
          # words (the {SHELL_METACHARACTERS} gate, the {SAFE_REDIRECT}
          # strip and quote removal all live there), so a consumer
          # receives clean, de-quoted word arrays and never re-splits a
          # string. See the class header for why the split is faithful and
          # why quote removal (single, and inert double) is sound.
          #
          # @param command [String] the command (a +bin/pikuri-*+ caller
          #   should strip any +"$ "+ echo prefix first).
          # @return [Array<Array<String>>, nil] one de-redirected, de-quoted
          #   word list per segment (an empty list marks a pure-comment
          #   no-op segment), or +nil+ — more than {MAX_CHAIN} segments, an
          #   unbalanced quote, a {DQUOTE_LIVE} byte inside double quotes,
          #   or any segment empty (a dangling sequencer) or not a simple
          #   invocation (metacharacter, unsafe redirect, …).
          def tokenize(command)
            segments = split_segments(command)
            return nil if segments.nil?

            words_per_segment = segments.map { |segment| scan_segment(segment) }
            return nil if words_per_segment.any?(&:nil?)

            words_per_segment
          end

          private

          # Split the command into raw segment strings on the {SEQUENCERS}
          # operators, but only *outside* quotes — so a quoted operator
          # (+echo 'a | b'+, +echo "a | b"+) stays inside its segment as
          # literal data. The quote marks themselves are preserved here
          # and removed later, per segment, by {.scan_segment}. This
          # tracker is escape-blind (it closes a span at a +\"+ that bash
          # would treat as escaped), which is safe because such a command
          # necessarily carries a +\+ into some segment and
          # {.scan_segment} rejects it — see the class header.
          #
          # @param command [String] the command.
          # @return [Array<String>, nil] the raw segments (quotes intact;
          #   empty strings kept, so a dangling/doubled operator yields an
          #   empty segment that {.scan_segment} rejects), or +nil+ on an
          #   unbalanced quote or more than {MAX_CHAIN} segments.
          def split_segments(command)
            segments = []
            buf = +''
            quote = nil # the quote character we are inside, or nil
            i = 0
            while i < command.length
              char = command[i]
              if quote
                buf << char
                quote = nil if char == quote
                i += 1
              elsif char == "'" || char == '"'
                buf << char
                quote = char
                i += 1
              elsif (op = SEQUENCERS.match(command, i)) && op.begin(0) == i
                segments << buf
                buf = +''
                i += op[0].length
              else
                buf << char
                i += 1
              end
            end
            return nil if quote

            segments << buf
            segments.size > MAX_CHAIN ? nil : segments
          end

          # Reduce one sequencer segment to its de-quoted word list, or
          # +nil+ to signal the whole command must be rejected.
          #
          # A left-to-right scan that performs shell quote removal — the
          # quote marks are dropped and the interior is kept *verbatim*
          # and *literal* (an interior +|+, +;+ neither splits nor trips
          # the gate), so the word handed back is the true argument
          # (+--clear+, never +--_clear+ — see the class header on why a
          # placeholder rewrite is unsafe). A single-quoted interior is
          # literal unconditionally; a double-quoted one only until a
          # {DQUOTE_LIVE} byte (+$+, backtick, +\+) appears, which rejects
          # the segment. Outside quotes the bytes are classified:
          # whitespace ends a word, a {SAFE_REDIRECT} fragment is consumed
          # and dropped, a {SHELL_METACHARACTERS} byte rejects.
          #
          # @param segment [String] one {SEQUENCERS} segment, not yet
          #   stripped.
          # @return [Array<String>, nil] the segment's de-quoted words with
          #   any {SAFE_REDIRECT} fragments removed; +[]+ for a pure-comment
          #   segment (a no-op); or +nil+ — an empty segment (a dangling
          #   sequencer), an unbalanced quote, a {DQUOTE_LIVE} byte inside
          #   double quotes, a {SHELL_METACHARACTERS} byte (incl. +\+), or
          #   a redirect that is not write-nothing.
          def scan_segment(segment)
            command = segment.strip
            return nil if command.empty?

            # A segment starting with +#+ is a shell comment — it executes
            # nothing, so it is a no-op. Sound because every segment
            # boundary is a command separator, where +#+ genuinely opens a
            # comment; a mid-segment +#+ (+ls #+) does not start the
            # segment and so still trips the gate below.
            return [] if command.start_with?('#')

            words = []
            word = nil          # current word buffer; nil between words
            quote = nil         # the quote character we are inside, or nil
            i = 0
            while i < command.length
              char = command[i]
              if quote == "'"
                # Single-quote interior: literal, never a separator/metachar.
                char == "'" ? (quote = nil) : (word = (word || +'') << char)
                i += 1
              elsif quote == '"'
                # Double-quote interior: literal too — unless one of the
                # POSIX-live bytes appears, which rejects the segment.
                if char == '"'
                  quote = nil
                elsif DQUOTE_LIVE.match?(char)
                  return nil
                else
                  word = (word || +'') << char
                end
                i += 1
              elsif char == "'" || char == '"'
                word ||= +''     # an opening quote starts a (maybe empty) word
                quote = char
                i += 1
              elsif char == ' ' || char == "\t"
                words << word unless word.nil?
                word = nil
                i += 1
              elsif char == '>' || (char == '&' && command[i + 1] == '>')
                # A redirect. Anchor {SAFE_REDIRECT} at the fd prefix (the
                # trailing digits of the current word, e.g. the +2+ of
                # +2>&1+), accepting only the write-nothing forms; anything
                # else (a real target) returns +nil+. The fd digits belonged
                # to the redirect, not the word, so trim them off.
                digits = char == '>' && word ? word[/\d*\z/].length : 0
                redirect = SAFE_REDIRECT.match(command, i - digits)
                return nil unless redirect && redirect.begin(0) == i - digits

                if digits.positive?
                  word = word[0...-digits]
                  word = nil if word.empty?
                end
                words << word unless word.nil?
                word = nil
                i = redirect.end(0)
              elsif SHELL_METACHARACTERS.match?(char)
                return nil
              else
                word = (word || +'') << char
                i += 1
              end
            end
            return nil if quote

            words << word unless word.nil?
            words.empty? ? nil : words
          end
        end
      end
    end
  end
end
