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
      # human. See +ideas/os-assistant.md+.
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
      #   the backslash, so nothing could have quoted/escaped a +;+, +|+
      #   or newline into a literal. And every *other* metacharacter stays
      #   forbidden per segment, so an arbitrary-target redirect
      #   (+ps | grep x > out+), a background +&+ (+ls & pwd+ — +&+ is not
      #   a sequencer), or +|&+ all trip the metacharacter check ⇒ the
      #   whole command delegates. The lone exception is a write-nothing
      #   redirect fragment ({SAFE_REDIRECT}: +2>&1+, +2>/dev/null+ …),
      #   stripped per-segment *before* the gate — fd duplication and
      #   +/dev/null+ discards add no capability (see {#simple_read_only?}).
      #   Only the sequencers can appear across the command.
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
      # * +journalctl+ — its read vs. mutate split is by *flag*
      #   (+--vacuum-*+ / +--rotate+ / +--flush+), not a leading
      #   subcommand, so the immediately-after-the-binary trick the
      #   subcommand classifiers below rely on doesn't apply; recovering
      #   it cleanly needs a flag denylist, still deferred — v1 delegates
      #   it. (+systemctl+ *is* subcommand-shaped and is recovered below;
      #   +dmesg+ is the same flag-split shape and *is* recovered, by the
      #   flag denylist described next.)
      # * +find+ (+-delete+/+-exec+), +env+/+command+ (run other
      #   programs), +date+/+hostname+ (have set-forms).
      #
      # == Read-only subcommand queries (+dpkg+ / +apt+ / +systemctl+), unconditional
      #
      # +dpkg+, +apt+ and +systemctl+ are mixed binaries whose *query*
      # forms are read-only but whose mutating forms are not
      # (+dpkg -i+/+-r+/+--purge+, +apt install+/+remove+/+update+,
      # +systemctl start+/+stop+/+enable+) — so they cannot join
      # {READ_ONLY_BINARIES} wholesale. {#read_only_dpkg?},
      # {#read_only_apt?} and {#read_only_systemctl?} recover the query
      # subset the same way {#read_only_git?} recovers read-only git: the
      # read-only action/subcommand must appear *immediately* after the
      # binary name ({READ_ONLY_DPKG_ACTIONS} / {READ_ONLY_APT_SUBCOMMANDS}
      # / {READ_ONLY_SYSTEMCTL_SUBCOMMANDS}), which refuses a leading
      # redirection or global option (+dpkg --admindir=/x …+,
      # +apt -o APT::Foo=bar …+, +systemctl --root=/x …+) by making the
      # second token not a known query verb.
      #
      # Unlike git, these are *unconditional* (no +allow_git:+-style
      # gate): the query forms read the package database / cache / unit
      # state and have no command-execution vector — apt's pre/post-invoke
      # hooks fire on install/update (never on +search+/+show+), and
      # +systemctl+ spawns its pager only on a tty, which {Bash}'s captured
      # (piped) stdout is not. The pure-query companion binaries
      # +dpkg-query+ and +apt-cache+ have no mutating form at all and so
      # sit directly in {READ_ONLY_BINARIES}.
      #
      # == Read-only dmesg (flag denylist), unconditional
      #
      # +dmesg+ prints the kernel ring buffer read-only by default, but a
      # handful of *flags* mutate kernel/console state: +-C+/+--clear+ and
      # +-c+/+--read-clear+ wipe the buffer, +-D+/+--console-off+ /
      # +-E+/+--console-on+ toggle console printing, +-n+/+--console-level+
      # sets it. The read/mutate split is by flag (like +journalctl+, unlike
      # the subcommand-shaped trio above), so {#read_only_dmesg?} recovers it
      # with a *denylist*: a +dmesg+ invocation auto-approves iff none of its
      # arguments is a mutating flag ({DMESG_MUTATING_SHORT} /
      # {DMESG_MUTATING_LONG}). Bundled short options are caught
      # character-by-character (+-xC+ contains the +C+ clear, so it
      # delegates), and a long option's +=value+ tail is stripped before the
      # lookup (+--console-level=1+ matches +--console-level+); a long form
      # written spaced (+--console-level 1+) is caught on its flag token.
      # Everything else +dmesg+ does only reads, so the default-on read mode
      # needs no allowlisting — a bare value token (a level name, a glued
      # read-only flag) just passes.
      #
      # This is the one deviation from the otherwise-absolute "never
      # auto-approve a destructive command": a denylist's residual is a
      # *future* +dmesg+ mutating flag this set doesn't yet name, which would
      # auto-approve. It's the same residual shape the git +--output+ check
      # already carries (a future read-verb file-writer flag would slip), and
      # +dmesg+'s mutating surface is small and stable (util-linux), so the
      # residual is accepted; an allowlist of read-only flags would close it
      # at the cost of delegating every new read flag, which is the inferior
      # trade here. The guarantee is privilege-independent as before
      # (+dmesg+ often needs root to *work*, but that's orthogonal to whether
      # the form mutates).
      #
      # == Read-only git (+allow_git:+, opt-in, default off)
      #
      # Everything above is *unconditional* — it assumes nothing about the
      # repository. +allow_git: true+ relaxes that one notch: it
      # additionally auto-approves the read-only git verbs
      # ({READ_ONLY_GIT_SUBCOMMANDS} — +git diff+/+status+/+log+/+show+ …,
      # with +git diff --cached+ and friends accepted for free, see
      # {#read_only_git?}). Even a bare +git diff+ executes whatever the
      # repo config directs (+core.fsmonitor+, +diff.*.textconv+), so
      # auto-approving it is only sound when that config-execution vector
      # is contained.
      #
      # Containment is provided by {Pikuri::Code::Bash}, not by this
      # decorator: {Pikuri::Code::Bash::GIT_HARDENING} forces
      # +core.fsmonitor=false+ (and +core.pager=cat+) onto every git
      # subprocess via the +GIT_CONFIG_*+ environment, overriding a hostile
      # repo-local +.git/config+ — so the headline vector (+core.fsmonitor
      # = rm -rf ~+, which fires on a plain +git status+) is closed for any
      # +Bash+-wired agent. The *residual* the caller accepts with
      # +allow_git: true+ is therefore narrow: diff-driver execution
      # (+diff.external+, or a +.gitattributes+-selected
      # +diff.<driver>.command+/+.textconv+), which the environment cannot
      # disable cleanly and we do not rewrite the command to suppress. A
      # plain +git clone+ never copies the remote's config, so that
      # residual is confined to a repo whose +.git/config+ an attacker
      # wrote (a tarball with +.git/+ intact, a shared/synced dir, or
      # config a build step left behind). Two wirings make the trade-off
      # differently: +bin/pikuri-code+ still gates +allow_git: true+ behind
      # a startup "trust this repo's config?" prompt; +pikuri-os+ enables
      # it unconditionally and documents the residual (its agent roams the
      # whole disk, so there is no single repo to vouch for — see
      # +Pikuri::Os::Extension+ and +ideas/os-assistant.md+).
      #
      # Hardening does NOT license *destructive* git (the LLM, steered by
      # other untrusted content, could still emit +git reset --hard+), so
      # the verb set excludes every mutating form and {#read_only_git?}
      # additionally refuses inline config / repo-redirection / +--output+.
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
        #
        # A newline is included because it is a command *terminator*
        # exactly like +;+ — a multi-line script is a sequence of
        # commands. The faithfulness argument carries over unchanged: a
        # newline that was meant literally (inside a quoted string) can't
        # appear in an auto-approvable command, because the per-segment
        # check forbids both quote characters outright.
        SEQUENCERS = /&&|\|\||;|\||\n/

        # Defensive ceiling on the number of sequencer-joined segments.
        # The split and per-segment checks are linear and cheap, so this
        # is only a sanity backstop against pathological input, set high
        # enough to clear a real generated batch (e.g. a +dpkg -S … || true+
        # probe per unit file across dozens of files); beyond it the whole
        # command simply delegates to the human rather than being analyzed.
        MAX_CHAIN = 64

        # Binaries that are read-only in *every* argument form (no
        # mutating mode reachable, with or without root). See the class
        # header for the curation principle and notable exclusions.
        #
        # +cd+, +true+ and +false+ are shell builtins rather than PATH
        # binaries; the classifier only string-matches the first token,
        # so they slot in cleanly. None has a destructive form. +cd+ is
        # meaningful only inside a sequencer chain (+cd notes && ls+); a
        # bare +cd+ alone auto-approves harmlessly, changing the dir of a
        # subshell that immediately exits. +true+/+false+ are pure
        # exit-status no-ops — their value is the ubiquitous +cmd || true+
        # idiom that swallows a probe's failure (+dpkg -S x || true+), so
        # the +true+ tail-segment must classify as read-only for the whole
        # chain to auto-approve.
        READ_ONLY_BINARIES = Set[
          'cd', 'true', 'false',
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
          'locale', 'getconf',
          'dpkg-query', 'apt-cache'
        ].freeze

        # A redirect fragment that writes nothing to the filesystem,
        # stripped from a segment before the {SHELL_METACHARACTERS} gate
        # runs (it contains +>+/+&+, which the gate otherwise rejects).
        # Two safe families only:
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
        # (+2>/dev/nullx+, +2>/dev/null.bak+) does not match, survives,
        # and trips the gate ⇒ delegates — as does any arbitrary-file
        # redirect (+2>/etc/passwd+, +> out+). +\s*+ accepts the operator
        # and target either glued (+2>/dev/null+) or spaced (+> /dev/null+).
        # The fragment contains no {SEQUENCERS} byte, so stripping happens
        # per-segment, after the faithful split.
        SAFE_REDIRECT = %r{[0-9]*>&[0-9]+|(?:[0-9]|&)?>>?\s*/dev/null(?=\s|\z)}

        # +systemctl+ subcommands with no mutating form — the only
        # +systemctl+ invocations {#read_only_systemctl?} accepts (and,
        # like dpkg/apt, the verb must appear *immediately* after
        # +systemctl+, so a leading global such as +--root=/x+ delegates).
        # Deliberately excludes every state mutator (+start+/+stop+/
        # +restart+/+reload+/+enable+/+disable+/+mask+/+unmask+/+isolate+/
        # +kill+/+daemon-reload+/+set-default+/+reset-failed+/+edit+).
        # These only read unit/job state; +systemctl+ pages output solely
        # on a tty, and {Bash} captures stdout (a pipe), so the pager
        # never spawns — the one exec vector is closed by the wiring, not
        # this set.
        READ_ONLY_SYSTEMCTL_SUBCOMMANDS = Set[
          'list-units', 'list-unit-files', 'list-timers', 'list-sockets',
          'list-jobs', 'list-dependencies', 'status', 'show', 'cat',
          'is-active', 'is-enabled', 'is-failed', 'get-default'
        ].freeze

        # +dpkg+ action flags with no mutating form — the only +dpkg+
        # invocations {#read_only_dpkg?} accepts. Each must appear
        # immediately after +dpkg+ (so a leading +--admindir+/+--root+
        # redirection delegates). +--get-selections+ dumps the
        # selection state and is the read-side sibling of the excluded
        # +--set-selections+. Deliberately excludes every database
        # mutator (+-i+/+--install+, +-r+/+--remove+, +-P+/+--purge+,
        # +--unpack+, +--configure+, +-A+, +--update-avail+,
        # +--clear-avail+, +--set-selections+, +--clear-selections+).
        READ_ONLY_DPKG_ACTIONS = Set[
          '-l', '--list', '-L', '--listfiles', '-s', '--status',
          '-S', '--search', '-p', '--print-avail', '--get-selections'
        ].freeze

        # +apt+ subcommands that only query the package cache — the only
        # +apt+ invocations {#read_only_apt?} accepts. Each must appear
        # immediately after +apt+ (so a leading +-o Foo=bar+ config
        # injection delegates). These run no pre/post-invoke hooks — those
        # fire only on the mutating verbs (+install+/+remove+/+update+/
        # +upgrade+/+purge+/+autoremove+), which are excluded.
        READ_ONLY_APT_SUBCOMMANDS = Set[
          'search', 'show', 'list', 'policy', 'depends', 'rdepends'
        ].freeze

        # git verbs with no mutating form in any argument — the only git
        # commands {#read_only_git?} accepts (and only under +allow_git:+).
        # Deliberately excludes +tag+/+branch+/+remote+/+stash+/+reflog+
        # (each has a delete/create/expire form) and every working-tree /
        # ref mutator (+checkout+ +switch+ +restore+ +reset+ +clean+
        # +commit+ +merge+ +rebase+ +pull+ +push+ +config+ +gc+ …).
        READ_ONLY_GIT_SUBCOMMANDS = Set[
          'status', 'diff', 'log', 'show', 'blame',
          'rev-parse', 'describe', 'shortlog'
        ].freeze

        # +dmesg+ short-option *letters* that mutate kernel/console state —
        # the buffer wipers (+-C+ clear, +-c+ read-clear) and the console
        # controls (+-D+ off, +-E+ on, +-n+ set-level). {#read_only_dmesg?}
        # scans each short-option cluster character-by-character against this
        # set, so a bundled +-xC+ is caught on its +C+. Every other +dmesg+
        # flag only reads.
        DMESG_MUTATING_SHORT = Set['C', 'c', 'D', 'E', 'n'].freeze

        # +dmesg+ long options that mutate kernel/console state — the
        # long-form spellings of {DMESG_MUTATING_SHORT}. {#read_only_dmesg?}
        # strips a +=value+ tail before the lookup, so +--console-level=1+
        # matches +--console-level+.
        DMESG_MUTATING_LONG = Set[
          '--clear', '--read-clear', '--console-off', '--console-on',
          '--console-level'
        ].freeze

        # @param inner [Pikuri::Workspace::Confirmer] the confirmer to
        #   delegate to whenever a command is not provably read-only
        #   (typically {Pikuri::Workspace::Confirmer::TERMINAL}).
        # @param allow_git [Boolean] when +true+, additionally auto-approve
        #   read-only git invocations ({#read_only_git?}). Default +false+.
        #   Sound only when paired with {Pikuri::Code::Bash}'s git
        #   environment hardening ({Pikuri::Code::Bash::GIT_HARDENING}),
        #   which closes the +core.fsmonitor+ config-execution vector; the
        #   caller accepts the narrow diff-driver residual (see the class
        #   header). +bin/pikuri-code+ gates this behind a startup trust
        #   prompt; +pikuri-os+ enables it unconditionally.
        def initialize(inner, allow_git: false)
          super()
          @inner = inner
          @allow_git = allow_git
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
        #   metacharacter-free invocation of a {READ_ONLY_BINARIES} entry
        #   (or a read-only +dpkg+/+apt+/+systemctl+ query, or — under
        #   +allow_git:+ — a read-only git invocation). A pure-comment
        #   segment (one beginning with +#+) is a no-op and auto-approves.
        def simple_read_only?(command)
          return false if command.empty?

          # A segment starting with +#+ is a shell comment — it executes
          # nothing, so it is trivially read-only. Sound because every
          # segment boundary is a command separator, where +#+ genuinely
          # opens a comment; a mid-segment +#+ (+ls #+) does not start
          # the segment and so still trips the gate below.
          return true if command.start_with?('#')

          # Drop the write-nothing redirect fragments before the gate,
          # which would otherwise reject their +>+/+&+. Only fd-dups and
          # +/dev/null+ discards match (see {SAFE_REDIRECT}); anything
          # else survives and trips.
          bare = command.gsub(SAFE_REDIRECT, ' ')
          return false if SHELL_METACHARACTERS.match?(bare)

          first = bare.split(/\s+/).first
          return false if first.nil? || first.include?('/')
          return true if READ_ONLY_BINARIES.include?(first)
          return true if read_only_dpkg?(command)
          return true if read_only_apt?(command)
          return true if read_only_systemctl?(command)
          return true if read_only_dmesg?(command)

          @allow_git && read_only_git?(command)
        end

        # @param command [String] one sequencer segment, already stripped
        #   and guaranteed metacharacter-free by {#simple_read_only?}.
        # @return [Boolean] whether it is a read-only +dpkg+ query: +dpkg+
        #   followed *immediately* by a {READ_ONLY_DPKG_ACTIONS} flag.
        #   Requiring the action right after +dpkg+ refuses a leading
        #   +--admindir+/+--root+ redirection (the second token would not
        #   be a known query action) as well as every install/remove form.
        def read_only_dpkg?(command)
          tokens = command.split(/\s+/)
          return false unless tokens[0] == 'dpkg'

          READ_ONLY_DPKG_ACTIONS.include?(tokens[1])
        end

        # @param command [String] one sequencer segment, already stripped
        #   and guaranteed metacharacter-free by {#simple_read_only?}.
        # @return [Boolean] whether it is a read-only +apt+ query: +apt+
        #   followed *immediately* by a {READ_ONLY_APT_SUBCOMMANDS} verb.
        #   Requiring the verb right after +apt+ refuses a leading
        #   +-o Foo=bar+ config injection and every mutating verb.
        def read_only_apt?(command)
          tokens = command.split(/\s+/)
          return false unless tokens[0] == 'apt'

          READ_ONLY_APT_SUBCOMMANDS.include?(tokens[1])
        end

        # @param command [String] one sequencer segment, already stripped
        #   and guaranteed metacharacter-free by {#simple_read_only?}.
        # @return [Boolean] whether it is a read-only +systemctl+ query:
        #   +systemctl+ followed *immediately* by a
        #   {READ_ONLY_SYSTEMCTL_SUBCOMMANDS} verb. Requiring the verb
        #   right after +systemctl+ refuses a leading global option
        #   (+--root=/x+, +-H host+) and every state-mutating verb.
        def read_only_systemctl?(command)
          tokens = command.split(/\s+/)
          return false unless tokens[0] == 'systemctl'

          READ_ONLY_SYSTEMCTL_SUBCOMMANDS.include?(tokens[1])
        end

        # @param command [String] one sequencer segment, already stripped
        #   and guaranteed metacharacter-free by {#simple_read_only?}.
        # @return [Boolean] whether it is a read-only +dmesg+ invocation:
        #   +dmesg+ with no mutating flag among its arguments
        #   ({DMESG_MUTATING_SHORT} / {DMESG_MUTATING_LONG}). Bundled short
        #   options are scanned per character (+-xC+ trips on +C+); a long
        #   option's +=value+ tail is dropped before the lookup. Non-flag
        #   tokens (level names, a surviving +/dev/null+ redirect fragment)
        #   are read-only data and pass.
        def read_only_dmesg?(command)
          tokens = command.split(/\s+/)
          return false unless tokens[0] == 'dmesg'

          tokens.drop(1).none? { |t| dmesg_mutating_arg?(t) }
        end

        # @param token [String] one whitespace-delimited +dmesg+ argument.
        # @return [Boolean] whether it names a mutating +dmesg+ flag — a long
        #   option in {DMESG_MUTATING_LONG} (ignoring any +=value+ tail), or
        #   a short-option cluster containing a {DMESG_MUTATING_SHORT} letter.
        #   A bare value token (no leading +-+) is read-only data ⇒ +false+.
        def dmesg_mutating_arg?(token)
          if token.start_with?('--')
            DMESG_MUTATING_LONG.include?(token.split('=', 2).first)
          elsif token.start_with?('-')
            token[1..].chars.any? { |c| DMESG_MUTATING_SHORT.include?(c) }
          else
            false
          end
        end

        # @param command [String] one sequencer segment, already stripped
        #   and guaranteed metacharacter-free by {#simple_read_only?}.
        # @return [Boolean] whether it is a read-only git invocation: +git+
        #   followed *immediately* by a {READ_ONLY_GIT_SUBCOMMANDS} verb,
        #   with no +--output+ argument. Requiring the verb immediately
        #   after +git+ refuses a leading global option
        #   (+git -c core.pager=evil diff+, +git -C /other diff+,
        #   +--git-dir+, +--exec-path+) — the inline-config and
        #   repo-redirection escapes — since that makes the second token
        #   start with +-+. +--output+ is the one in-tool file writer
        #   reachable in this verb set (+git diff --output=f+). Redirects /
        #   pipes / substitution are already impossible here —
        #   {SHELL_METACHARACTERS} ran first. +git diff --cached+ /
        #   +--staged+ / +--stat+ / pathspecs are accepted for free (just
        #   non-+--output+ tokens after the verb).
        def read_only_git?(command)
          tokens = command.split(/\s+/)
          return false unless tokens[0] == 'git'
          return false unless READ_ONLY_GIT_SUBCOMMANDS.include?(tokens[1])

          tokens.drop(2).none? { |t| t.start_with?('--output') }
        end
      end
    end
  end
end
