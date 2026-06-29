# frozen_string_literal: true

require 'set'

module Pikuri
  module Code
    class Bash
      # A {Pikuri::Workspace::Confirmer} decorator that auto-approves
      # *provably* read-only bash commands and delegates everything else
      # to a wrapped (human) confirmer. The conservative half of the
      # OS-helper's answer to confirmation fatigue: the frequent harmless
      # commands (+ls+, +cat+, +grep+, +df+ …) stop prompting, while every
      # mutation — and anything it can't prove safe — still reaches the
      # human. See +ideas/os-assistant.md+ §"Confirmation fatigue".
      #
      # == Why fatigue is a security concern, not just UX
      #
      # A user who has clicked "yes" forty times this session has stopped
      # reading; the forty-first prompt — the hallucinated or injected one
      # — gets rubber-stamped. Cutting the volume of pointless prompts is
      # what keeps attention on the prompts that matter. This decorator
      # exists to make confirmations *rare and meaningful*.
      #
      # == The decision rule (deny-by-default)
      #
      # The command is split on the shell *sequencer / pipe* operators
      # ({SEQUENCERS}: +&&+, +||+, +;+, +|+) into one or more *segments*
      # (at most {MAX_CHAIN}); the command auto-approves iff *every*
      # segment is a provably-read-only simple invocation — ALL of the
      # following hold per segment, otherwise the whole command is
      # delegated to the wrapped confirmer:
      #
      # 1. It contains no shell metacharacter or control byte
      #    ({SHELL_METACHARACTERS}). After the sequencer split, what a
      #    segment may still illegally contain is a *redirect* (+>+ +<+),
      #    background +&+, +$(...)+, backtick, glob, brace/tilde
      #    expansion, quote, or escape — any of those means "more than a
      #    single simple invocation" and we refuse it. (+$(rm -rf ~)+,
      #    +echo x > /etc/passwd+, +ls *.txt+ all fail here.)
      # 2. The first token is a *bare* command name — no +/+. +./ls+,
      #    +/tmp/ls+, +bin/ls+ are paths that could point at a planted
      #    binary, so they delegate; only PATH-resolved bare names
      #    (+ls+, +cat+, …) qualify.
      # 3. That bare name is on {READ_ONLY_BINARIES}.
      #
      # The failure mode is always "asks the human too often," never
      # "auto-approved something destructive."
      #
      # == Why splitting on the sequencers is safe (the faithful-split argument)
      #
      # A composition of provably-read-only invocations joined only by
      # sequencing/pipe operators is itself read-only, so +ps aux | grep
      # ssh+, +cd notes && ls+, +df -h ; free -m+ should auto-approve as
      # readily as a single +ls+. Two facts make it sound:
      #
      # * *The split is faithful.* Every operator we cut on is a genuine
      #   control operator, never one hidden inside a string — because the
      #   per-segment check in (1) still forbids both quote characters and
      #   the backslash, so nothing could have quoted/escaped a +;+ or +|+
      #   into a literal. And every *other* metacharacter stays forbidden
      #   per segment, so a redirect (+ps | grep x > out+), a background
      #   +&+ (+ls & pwd+ — +&+ is not a sequencer), +|&+, or +&>+ all trip
      #   the metacharacter check ⇒ the whole command delegates. Only the
      #   four sequencers can appear across the command.
      # * *A pipe grants no new capability.* +|+ wires stdout→stdin as
      #   *data*. No {READ_ONLY_BINARIES} entry writes a file or executes
      #   a program from its stdin — they are pure transducers (+grep+,
      #   +wc+, +head+, +od+, +strings+, +cat+ …). The data→action
      #   escalators (+xargs+, +sh+, +tee+) are *not* on the allowlist, so
      #   a pipe cannot turn read data into a write or an exec.
      #
      # This holds regardless of egress: each segment must still be an
      # allowlisted read-only binary, none of which can write or
      # exfiltrate.
      #
      # == Why a binary allowlist, and why it's short
      #
      # Metacharacter-free is *necessary but not sufficient*: +find .
      # -delete+, +sort -o f+, +systemctl stop x+, +git reset --hard+,
      # +dd+, +tee+, +truncate+, +shred+, +date -s+, +journalctl
      # --vacuum-time=1s+ are all single, metacharacter-free, *destructive*
      # invocations. So {READ_ONLY_BINARIES} holds only binaries with **no
      # mutating form in any argument** — independent of privilege, so the
      # guarantee doesn't rely on the agent running non-root. That
      # deliberately excludes some otherwise-common tools:
      #
      # * +journalctl+ / +systemctl+ — core to an OS helper, but each has
      #   metacharacter-free destructive subcommands (+--vacuum-*+,
      #   +stop+/+disable+). Recovering their *read* subcommands
      #   (+systemctl status+, plain +journalctl+) needs subcommand-aware
      #   rules — a deliberate v2 refinement; v1 just delegates them.
      # * +find+ (+-delete+/+-exec+), +env+/+command+ (run other
      #   programs), +date+/+hostname+ (have set-forms).
      #
      # == Residual the allowlist does NOT close
      #
      # PATH hijacking: a bare +ls+ resolves via +$PATH+, so a planted
      # +~/bin/ls+ earlier in +PATH+ would run instead of the system one.
      # Planting requires a prior *confirmed* write, and altering +PATH+
      # within the same command needs +export+/+;+ (metacharacters →
      # delegated), so this needs at least one human-approved step; it is
      # not a one-command bypass. Documented, accepted for v1.
      #
      # == Wiring
      #
      # +Bash.new(confirmer: ReadOnlyAutoConfirmer.new(Confirmer::TERMINAL),
      # …)+. The decorator only auto-approves; it never *rejects* on its
      # own, so wrapping the terminal confirmer is always safe. It keys off
      # {Pikuri::Workspace::Confirmer::Request#detail}, which {Bash} sets to
      # +"$ <command>"+; a +nil+/other +detail+ (e.g. {Write}'s) simply
      # delegates.
      class ReadOnlyAutoConfirmer < Pikuri::Workspace::Confirmer
        # Any shell metacharacter or ASCII control byte. Presence of one
        # means the command is more than a single simple invocation (or is
        # trying to hide something), so it delegates. Note +=+ is *not*
        # here: it appears in ordinary long options (+--color=never+) and
        # is harmless except as a leading +VAR=val+ assignment, which is
        # caught anyway because the first token then isn't a bare allowed
        # binary.
        SHELL_METACHARACTERS = /[;&|<>$`()\\!#"'*?\[\]{}~\x00-\x1f]/

        # Shell control operators that merely *sequence or pipe*
        # commands. The command is split on these and each resulting
        # segment is checked independently. The split is faithful because
        # every other metacharacter (redirects, background +&+,
        # substitution, globs, quotes) stays in {SHELL_METACHARACTERS}
        # and is rejected per segment. Alternation order matters:
        # the two-char +&&+ / +||+ must be tried before the single +|+
        # so +a || b+ splits into two segments, not three.
        SEQUENCERS = /&&|\|\||;|\|/

        # Defensive ceiling on the number of sequencer-joined segments. A
        # legitimate read-only chain is short; a pathologically long
        # generated one simply delegates rather than being split.
        MAX_CHAIN = 8

        # Binaries that are read-only in *every* argument form (no
        # mutating mode reachable, with or without root). See the class
        # header for the curation principle and notable exclusions.
        #
        # +cd+ is the one entry that is a shell builtin rather than a
        # PATH binary; the classifier only string-matches the first
        # token, so it slots in cleanly. It has no destructive form and
        # is meaningful only inside a sequencer chain (+cd notes && ls+);
        # a bare +cd+ alone auto-approves harmlessly, changing the dir of
        # a subshell that immediately exits.
        READ_ONLY_BINARIES = Set[
          'cd',
          'ls', 'cat', 'tac', 'nl', 'head', 'tail', 'wc',
          'grep', 'egrep', 'fgrep', 'rg',
          'pwd', 'basename', 'dirname', 'realpath', 'readlink',
          'stat', 'file',
          'od', 'hexdump', 'xxd', 'strings',
          'cal',
          'uname', 'arch', 'nproc', 'lscpu', 'lsblk', 'lsusb', 'lspci',
          'df', 'du', 'free', 'vmstat', 'uptime', 'ps',
          'printenv', 'echo', 'printf',
          'whoami', 'id', 'groups',
          'which', 'type',
          'locale', 'getconf'
        ].freeze

        # @param inner [Pikuri::Workspace::Confirmer] the confirmer to
        #   delegate to whenever a command is not provably read-only
        #   (typically {Pikuri::Workspace::Confirmer::TERMINAL}).
        def initialize(inner)
          super()
          @inner = inner
        end

        # @param request [Pikuri::Workspace::Confirmer::Request]
        # @return [Boolean] +true+ (auto-approved) for a provably
        #   read-only command; otherwise whatever the wrapped confirmer
        #   returns.
        def confirm?(request:)
          return true if read_only?(request.detail)

          @inner.confirm?(request: request)
        end

        private

        # @param detail [String, nil] the request detail; {Bash} sets it
        #   to +"$ <command>"+.
        # @return [Boolean] whether the command is a {SEQUENCERS}-joined
        #   chain (one or more segments, up to {MAX_CHAIN}) of provably
        #   read-only simple invocations. See the class header for why
        #   splitting on the sequencers is faithful.
        def read_only?(detail)
          return false if detail.nil?

          command = detail.sub(/\A\$ /, '').strip
          return false if command.empty?

          # -1 keeps trailing/leading empty fields, so a dangling operator
          # (+ls &&+, +| ls+, +ls ;+) yields an empty segment and delegates
          # rather than being silently dropped.
          segments = command.split(SEQUENCERS, -1)
          return false if segments.size > MAX_CHAIN

          segments.all? { |segment| simple_read_only?(segment.strip) }
        end

        # @param command [String] one sequencer segment, already stripped.
        # @return [Boolean] whether it is a single, bare,
        #   metacharacter-free invocation of a {READ_ONLY_BINARIES} entry.
        def simple_read_only?(command)
          return false if command.empty?
          return false if SHELL_METACHARACTERS.match?(command)

          first = command.split(/\s+/).first
          return false if first.include?('/')

          READ_ONLY_BINARIES.include?(first)
        end
      end
    end
  end
end
