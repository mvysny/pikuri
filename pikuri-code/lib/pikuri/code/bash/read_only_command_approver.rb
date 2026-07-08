# frozen_string_literal: true

require 'set'

module Pikuri
  module Code
    class Bash
      # A predicate over bash command strings: {#approves?} is +true+ iff
      # the command is *provably* read-only. {Bash} consults it as its
      # +command_approver:+ — an approved command runs without a
      # confirmation prompt, while everything else (and anything not
      # provably safe) falls through to Bash's human {Confirmer}. The
      # conservative half of the OS-helper's answer to confirmation
      # fatigue: the frequent harmless commands (+ls+, +cat+, +grep+,
      # +df+ …) stop prompting, while every mutation still reaches the
      # human. See +ideas/os-assistant.md+.
      #
      # It is NOT a {Pikuri::Workspace::Confirmer}: it renders nothing and
      # only ever *approves or abstains* — a +false+ is not a rejection,
      # it just means "ask the human". Separating this content
      # classification from the confirmer is deliberate: a Confirmer's one
      # job is to resolve a request (a human chrome, or blanket
      # auto-approve), and it must never parse a command — see
      # {Pikuri::Workspace::Confirmer}. That split also makes +--yolo+
      # (blanket {Pikuri::Workspace::Confirmer::AutoApprove}) and read-only
      # auto-gating (this predicate) independent, composable axes rather
      # than a single tangled decorator.
      #
      # == Why fatigue is a security concern, not just UX
      #
      # A user who has clicked "yes" forty times this session has stopped
      # reading; the forty-first prompt — the hallucinated or injected one
      # — gets rubber-stamped. Cutting the volume of pointless prompts is
      # what keeps attention on the prompts that matter. This predicate
      # exists to make confirmations *rare and meaningful*.
      #
      # == The decision rule (deny-by-default)
      #
      # The command is parsed by {Tokenizer.tokenize} into one *word list*
      # per *sequencer segment* (+&&+/+||+/+;+/+|+/newline-joined), or
      # +nil+ when it is more than such a simple chain (a metacharacter, an
      # unsafe redirect, an unbalanced quote, too many segments) — in which
      # case the whole command is not approved (fall through to the human).
      # When the parse succeeds the command approves iff *every* segment is
      # a provably-read-only simple invocation — both of the following
      # hold, otherwise it is not approved:
      #
      # 1. The first word is a *bare* command name — no +/+. +./ls+,
      #    +/tmp/ls+, +bin/ls+ are paths that could point at a planted
      #    binary, so they are not approved; only PATH-resolved bare names
      #    (+ls+, +cat+, …) qualify.
      # 2. That bare name is on {READ_ONLY_BINARIES} (or the segment is a
      #    read-only +dpkg+/+apt+/+systemctl+/+dmesg+ query, or — under
      #    +allow_git:+ — a read-only git invocation).
      #
      # The lexing half — why the sequencer split is faithful, why a pipe
      # grants no capability, and why quotes (single, and double with a
      # verifiably inert interior) are decoded by *real* quote-removal (so
      # this class receives the genuine de-quoted word,
      # +--clear+ not +--_clear+) — lives in {Tokenizer}. The relevant
      # consequence here: the {Tokenizer} hands the classifiers below the
      # *true* de-quoted word, which is what makes the denylist/prefix
      # checks ({#read_only_dmesg?}, the git +--output+ refusal) sound — a
      # placeholder rewrite would let a quote-smuggled +--''clear+ slip
      # past them. The failure mode is always "asks the human too often,"
      # never "auto-approved something destructive."
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
      #   subcommand classifiers below rely on doesn't apply. It is the
      #   same flag-split shape as +dmesg+ and is recovered the same way,
      #   by the flag denylist described below. (+systemctl+ *is*
      #   subcommand-shaped and is recovered below.)
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
      # with a *denylist*: a +dmesg+ invocation approves iff none of its
      # arguments is a mutating flag ({DMESG_MUTATING_SHORT} /
      # {DMESG_MUTATING_LONG}). Bundled short options are caught
      # character-by-character (+-xC+ contains the +C+ clear, so it is
      # not approved), and a long option's +=value+ tail is stripped before
      # the lookup (+--console-level=1+ matches +--console-level+); a long
      # form written spaced (+--console-level 1+) is caught on its flag token.
      # Everything else +dmesg+ does only reads, so the default-on read mode
      # needs no allowlisting — a bare value token (a level name, a glued
      # read-only flag) just passes.
      #
      # This is the one deviation from the otherwise-absolute "never
      # auto-approve a destructive command": a denylist's residual is a
      # *future* +dmesg+ mutating flag this set doesn't yet name, which would
      # be approved. It's the same residual shape the git +--output+ check
      # already carries (a future read-verb file-writer flag would slip), and
      # +dmesg+'s mutating surface is small and stable (util-linux), so the
      # residual is accepted; an allowlist of read-only flags would close it
      # at the cost of not approving every new read flag, which is the
      # inferior trade here. The guarantee is privilege-independent as before
      # (+dmesg+ often needs root to *work*, but that's orthogonal to whether
      # the form mutates).
      #
      # == Read-only journalctl (flag denylist), unconditional
      #
      # +journalctl+ prints the systemd journal read-only by default; the
      # maintenance ops that mutate on-disk state are all *long flags* — the
      # space trimmers (+--vacuum-size+/+--vacuum-time+/+--vacuum-files+),
      # +--rotate+/+--flush+/+--relinquish-var+/+--smart-relinquish-space+,
      # and the two writers +--setup-keys+ (FSS key pair) and
      # +--update-catalog+ (catalog index). The read/mutate split is by flag
      # (like +dmesg+, unlike the subcommand-shaped trio above), so
      # {#read_only_journalctl?} recovers it with a *denylist*: a +journalctl+
      # invocation approves iff none of its arguments is a mutating flag
      # ({JOURNALCTL_MUTATING_LONG}), with a long option's +=value+ tail
      # stripped before the lookup (+--vacuum-time=1s+ matches
      # +--vacuum-time+). Unlike +dmesg+ there is no short companion set —
      # every journalctl maintenance op is long-only (+-k+/+-f+/+-r+/+-b+/
      # +-u+/+-o+/+-D+/+-n+/+-p+ all only read) — so a short-option cluster
      # never mutates. Like +systemctl+, journalctl's pager is its only exec
      # vector and spawns solely on a tty, which {Bash}'s captured (piped)
      # stdout is not.
      #
      # Same residual shape as +dmesg+: a *future* journalctl mutating flag
      # this set doesn't yet name would be approved. journalctl's
      # maintenance surface is small and stable (systemd), so the residual is
      # accepted; the inverse — an allowlist of read-only flags — would
      # not approve every new read flag, the inferior trade here.
      #
      # == Read-only git (+allow_git:+, opt-in, default off)
      #
      # Everything above is *unconditional* — it assumes nothing about the
      # repository. +allow_git: true+ relaxes that one notch: it
      # additionally approves the read-only git verbs
      # ({READ_ONLY_GIT_SUBCOMMANDS} — +git diff+/+status+/+log+/+show+ …,
      # with +git diff --cached+ and friends accepted for free, see
      # {#read_only_git?}). Even a bare +git diff+ executes whatever the
      # repo config directs (+core.fsmonitor+, +diff.*.textconv+), so
      # approving it is only sound when that config-execution vector
      # is contained.
      #
      # Containment is provided by {Pikuri::Code::Bash}, not by this
      # predicate: {Pikuri::Code::Bash::GIT_HARDENING} forces
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
      # within the same command needs +export+/+;+ (metacharacters → not
      # approved), so this needs at least one human-approved step; it is
      # not a one-command bypass. Documented, accepted for v1.
      #
      # == Wiring
      #
      # +Bash.new(command_approver: ReadOnlyCommandApprover.new, …)+ (or
      # +.new(allow_git: true)+). {Bash} passes {#approves?} the raw
      # command string; a non-command tool never consults this predicate at
      # all, so — unlike the old confirmer-decorator shape — there is no
      # cross-tool coupling to reason about.
      class ReadOnlyCommandApprover
        # Binaries that are read-only in *every* argument form (no
        # mutating mode reachable, with or without root). See the class
        # header for the curation principle and notable exclusions.
        #
        # +cd+, +true+ and +false+ are shell builtins rather than PATH
        # binaries; the classifier only string-matches the first token,
        # so they slot in cleanly. None has a destructive form. +cd+ is
        # meaningful only inside a sequencer chain (+cd notes && ls+); a
        # bare +cd+ alone approves harmlessly, changing the dir of a
        # subshell that immediately exits. +true+/+false+ are pure
        # exit-status no-ops — their value is the ubiquitous +cmd || true+
        # idiom that swallows a probe's failure (+dpkg -S x || true+), so
        # the +true+ tail-segment must classify as read-only for the whole
        # chain to approve.
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

        # +systemctl+ subcommands with no mutating form — the only
        # +systemctl+ invocations {#read_only_systemctl?} accepts (and,
        # like dpkg/apt, the verb must appear *immediately* after
        # +systemctl+, so a leading global such as +--root=/x+ is not
        # approved). Deliberately excludes every state mutator (+start+/
        # +stop+/+restart+/+reload+/+enable+/+disable+/+mask+/+unmask+/
        # +isolate+/+kill+/+daemon-reload+/+set-default+/+reset-failed+/
        # +edit+). These only read unit/job state; +systemctl+ pages output
        # solely on a tty, and {Bash} captures stdout (a pipe), so the pager
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
        # redirection is not approved). +--get-selections+ dumps the
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
        # injection is not approved). These run no pre/post-invoke hooks —
        # those fire only on the mutating verbs (+install+/+remove+/
        # +update+/+upgrade+/+purge+/+autoremove+), which are excluded.
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

        # +journalctl+ long options that mutate journal / FSS-key / catalog
        # state — the space-maintenance ops (+--rotate+, +--flush+,
        # +--relinquish-var+, +--smart-relinquish-space+, the three
        # +--vacuum-*+ trimmers) and the two on-disk writers (+--setup-keys+
        # generates the FSS key pair, +--update-catalog+ rebuilds the
        # message-catalog index). {#read_only_journalctl?} strips a +=value+
        # tail before the lookup, so +--vacuum-time=1s+ matches
        # +--vacuum-time+. Unlike {DMESG_MUTATING_SHORT} there is *no* short
        # companion set: every journalctl maintenance op is long-only — the
        # short options (+-k+/+-f+/+-r+/+-b+/+-u+/+-o+/+-D+/+-n+/+-p+ …) all
        # only read — so a short-option cluster never mutates.
        JOURNALCTL_MUTATING_LONG = Set[
          '--rotate', '--flush', '--relinquish-var',
          '--smart-relinquish-space',
          '--vacuum-size', '--vacuum-time', '--vacuum-files',
          '--setup-keys', '--update-catalog'
        ].freeze

        # @param allow_git [Boolean] when +true+, additionally approve
        #   read-only git invocations ({#read_only_git?}). Default +false+.
        #   Sound only when paired with {Pikuri::Code::Bash}'s git
        #   environment hardening ({Pikuri::Code::Bash::GIT_HARDENING}),
        #   which closes the +core.fsmonitor+ config-execution vector; the
        #   caller accepts the narrow diff-driver residual (see the class
        #   header). +bin/pikuri-code+ gates this behind a startup trust
        #   prompt; +pikuri-os+ enables it unconditionally.
        def initialize(allow_git: false)
          @allow_git = allow_git
        end

        # @param command [String, nil] the raw bash command string (as
        #   {Bash} received it — no +"$ "+ echo decoration).
        # @return [Boolean] whether the command {Tokenizer.tokenize}s into a
        #   sequencer-joined chain in which every segment is a provably
        #   read-only simple invocation ({#segment_read_only?}). A +nil+
        #   parse (more than a simple chain), a +nil+/empty command, is not
        #   approved.
        def approves?(command)
          return false if command.nil?

          command = command.strip
          return false if command.empty?

          segments = Tokenizer.tokenize(command)
          return false if segments.nil?

          segments.all? { |words| segment_read_only?(words) }
        end

        private

        # @param words [Array<String>] one segment's words from
        #   {Tokenizer} (+[]+ for a comment no-op).
        # @return [Boolean] whether the segment is a single, bare
        #   invocation of a {READ_ONLY_BINARIES} entry (or a read-only
        #   +dpkg+/+apt+/+systemctl+/+dmesg+/+journalctl+ query, or — under
        #   +allow_git:+ — a read-only git invocation), or an empty (comment)
        #   segment.
        #   A first word containing +/+ is a path that could point at a
        #   planted binary, so it is not approved.
        def segment_read_only?(words)
          return true if words.empty?

          first = words.first
          return false if first.include?('/')
          return true if READ_ONLY_BINARIES.include?(first)
          return true if read_only_dpkg?(words)
          return true if read_only_apt?(words)
          return true if read_only_systemctl?(words)
          return true if read_only_dmesg?(words)
          return true if read_only_journalctl?(words)

          @allow_git && read_only_git?(words)
        end

        # @param words [Array<String>] one segment's words, redirect
        #   fragments already removed and metacharacters rejected by
        #   {Tokenizer}.
        # @return [Boolean] whether it is a read-only +dpkg+ query: +dpkg+
        #   followed *immediately* by a {READ_ONLY_DPKG_ACTIONS} flag.
        #   Requiring the action right after +dpkg+ refuses a leading
        #   +--admindir+/+--root+ redirection (the second word would not
        #   be a known query action) as well as every install/remove form.
        def read_only_dpkg?(words)
          return false unless words[0] == 'dpkg'

          READ_ONLY_DPKG_ACTIONS.include?(words[1])
        end

        # @param words [Array<String>] one segment's words, redirect
        #   fragments already removed and metacharacters rejected by
        #   {Tokenizer}.
        # @return [Boolean] whether it is a read-only +apt+ query: +apt+
        #   followed *immediately* by a {READ_ONLY_APT_SUBCOMMANDS} verb.
        #   Requiring the verb right after +apt+ refuses a leading
        #   +-o Foo=bar+ config injection and every mutating verb.
        def read_only_apt?(words)
          return false unless words[0] == 'apt'

          READ_ONLY_APT_SUBCOMMANDS.include?(words[1])
        end

        # @param words [Array<String>] one segment's words, redirect
        #   fragments already removed and metacharacters rejected by
        #   {Tokenizer}.
        # @return [Boolean] whether it is a read-only +systemctl+ query:
        #   +systemctl+ followed *immediately* by a
        #   {READ_ONLY_SYSTEMCTL_SUBCOMMANDS} verb. Requiring the verb
        #   right after +systemctl+ refuses a leading global option
        #   (+--root=/x+, +-H host+) and every state-mutating verb.
        def read_only_systemctl?(words)
          return false unless words[0] == 'systemctl'

          READ_ONLY_SYSTEMCTL_SUBCOMMANDS.include?(words[1])
        end

        # @param words [Array<String>] one segment's words, redirect
        #   fragments already removed and metacharacters rejected by
        #   {Tokenizer}.
        # @return [Boolean] whether it is a read-only +dmesg+ invocation:
        #   +dmesg+ with no mutating flag among its arguments
        #   ({DMESG_MUTATING_SHORT} / {DMESG_MUTATING_LONG}). Bundled short
        #   options are scanned per character (+-xC+ trips on +C+); a long
        #   option's +=value+ tail is dropped before the lookup. Non-flag
        #   words (level names, a value argument) are read-only data and pass.
        def read_only_dmesg?(words)
          return false unless words[0] == 'dmesg'

          words.drop(1).none? { |t| dmesg_mutating_arg?(t) }
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

        # @param words [Array<String>] one segment's words, redirect
        #   fragments already removed and metacharacters rejected by
        #   {Tokenizer}.
        # @return [Boolean] whether it is a read-only +journalctl+
        #   invocation: +journalctl+ with no mutating flag among its
        #   arguments ({JOURNALCTL_MUTATING_LONG}). A long option's +=value+
        #   tail is dropped before the lookup; journalctl has no mutating
        #   short option, so a short-option cluster is read-only data and
        #   passes. Same flag-denylist shape as {#read_only_dmesg?}.
        def read_only_journalctl?(words)
          return false unless words[0] == 'journalctl'

          words.drop(1).none? { |t| journalctl_mutating_arg?(t) }
        end

        # @param token [String] one whitespace-delimited +journalctl+
        #   argument.
        # @return [Boolean] whether it names a mutating +journalctl+ long
        #   flag in {JOURNALCTL_MUTATING_LONG} (ignoring any +=value+ tail).
        #   A short-option cluster or a bare value token never mutates ⇒
        #   +false+.
        def journalctl_mutating_arg?(token)
          return false unless token.start_with?('--')

          JOURNALCTL_MUTATING_LONG.include?(token.split('=', 2).first)
        end

        # @param words [Array<String>] one segment's words, redirect
        #   fragments already removed and metacharacters rejected by
        #   {Tokenizer}.
        # @return [Boolean] whether it is a read-only git invocation: +git+
        #   followed *immediately* by a {READ_ONLY_GIT_SUBCOMMANDS} verb,
        #   with no +--output+ argument. Requiring the verb immediately
        #   after +git+ refuses a leading global option
        #   (+git -c core.pager=evil diff+, +git -C /other diff+,
        #   +--git-dir+, +--exec-path+) — the inline-config and
        #   repo-redirection escapes — since that makes the second word
        #   start with +-+. +--output+ is the one in-tool file writer
        #   reachable in this verb set (+git diff --output=f+). Redirects /
        #   pipes / substitution are already impossible here —
        #   {Tokenizer} ran first. +git diff --cached+ / +--staged+ /
        #   +--stat+ / pathspecs are accepted for free (just non-+--output+
        #   words after the verb).
        def read_only_git?(words)
          return false unless words[0] == 'git'
          return false unless READ_ONLY_GIT_SUBCOMMANDS.include?(words[1])

          words.drop(2).none? { |t| t.start_with?('--output') }
        end
      end
    end
  end
end
