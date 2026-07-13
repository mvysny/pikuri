# frozen_string_literal: true

require 'set'

module Pikuri
  module Code
    class Bash
      # A predicate over bash command strings: {#approves?} is +true+ iff the
      # command is *provably* read-only. {Bash} consults it as its
      # +command_approver:+ — an approved command runs without a confirmation
      # prompt; everything else (and anything not provably safe) falls through
      # to Bash's human {Confirmer}. The conservative half of the OS-helper's
      # answer to confirmation fatigue: the frequent harmless commands (+ls+,
      # +cat+, +grep+, +df+ …) stop prompting while every mutation still reaches
      # the human. See +ideas/os-assistant.md+.
      #
      # It is NOT a {Pikuri::Workspace::Confirmer}: it renders nothing and only
      # ever *approves or abstains* — +false+ is not a rejection, just "ask the
      # human". Keeping this content classification out of the confirmer is
      # deliberate: a Confirmer's one job is to resolve a request, and it must
      # never parse a command. That split also makes +--yolo+ (blanket
      # {Confirmer::AutoApprove}) and read-only auto-gating (this predicate)
      # independent, composable axes rather than one tangled decorator.
      #
      # Why fatigue is a *security* concern: a user who has clicked "yes" forty
      # times has stopped reading; the injected forty-first gets rubber-stamped.
      # Cutting pointless prompts is what keeps attention on the ones that
      # matter.
      #
      # == The decision rule (deny-by-default)
      #
      # {Tokenizer.tokenize} parses the command into one *word list* per
      # *sequencer segment* (+&&+/+||+/+;+/+|+/newline), or +nil+ when it is
      # more than such a simple chain (a metacharacter, unsafe redirect,
      # unbalanced quote, too many segments) — in which case the command is not
      # approved. On a successful parse the command approves iff *every* segment
      # is a provably-read-only simple invocation:
      #
      # 1. The first word is a *bare* command name — no +/+. +./ls+, +/tmp/ls+,
      #    +bin/ls+ are paths that could point at a planted binary; only
      #    PATH-resolved bare names (+ls+, +cat+, …) qualify.
      # 2. That bare name is on {READ_ONLY_BINARIES} (or the segment is a
      #    read-only +dpkg+/+apt+/+systemctl+/+dmesg+/+journalctl+ query, or —
      #    under +allow_git:+ — a read-only git invocation).
      #
      # The lexing half lives in {Tokenizer}. The consequence here: it hands the
      # classifiers below the *true* de-quoted word (+--clear+, not +--_clear+),
      # which is what makes the denylist / prefix checks sound — a placeholder
      # rewrite would let a quote-smuggled +--''clear+ slip past them. The
      # failure mode is always "asks the human too often", never "auto-approved
      # something destructive".
      #
      # == Why a binary allowlist, and why it's short
      #
      # Metacharacter-free is *necessary but not sufficient*: +find . -delete+,
      # +sort -o f+, +systemctl stop x+, +git reset --hard+, +dd+, +tee+,
      # +truncate+, +shred+, +date -s+ are all single, metacharacter-free,
      # *destructive* invocations. So {READ_ONLY_BINARIES} holds only binaries
      # with **no mutating form in any argument** — independent of privilege, so
      # the guarantee doesn't rely on running non-root. That excludes +find+
      # (+-delete+/+-exec+), +env+/+command+ (run other programs),
      # +date+/+hostname+ (set-forms), and +journalctl+ (recovered by flag
      # denylist below — its read/mutate split is by flag, not subcommand).
      #
      # == Read-only subcommand queries (+dpkg+ / +apt+ / +systemctl+), unconditional
      #
      # These are mixed binaries whose query forms read-only but whose mutating
      # forms (+dpkg -i+/+-r+, +apt install+/+remove+, +systemctl start+/+stop+)
      # aren't, so they can't join {READ_ONLY_BINARIES} wholesale.
      # {#read_only_dpkg?}/{#read_only_apt?}/{#read_only_systemctl?} recover the
      # query subset by requiring a known verb *immediately* after the binary
      # ({READ_ONLY_DPKG_ACTIONS} / {READ_ONLY_APT_SUBCOMMANDS} /
      # {READ_ONLY_SYSTEMCTL_SUBCOMMANDS}) — which refuses a leading redirection
      # or global option (+dpkg --admindir=/x+, +apt -o APT::Foo=bar+,
      # +systemctl --root=/x+) since the second token then isn't a query verb.
      #
      # Unlike git these are *unconditional* (no +allow_git:+-style gate): the
      # query forms read state with no command-execution vector — apt's
      # pre/post-invoke hooks fire only on install/update, and +systemctl+
      # spawns its pager only on a tty, which {Bash}'s captured (piped) stdout
      # is not. The pure-query companions +dpkg-query+ and +apt-cache+ have no
      # mutating form at all and sit directly in {READ_ONLY_BINARIES}.
      #
      # == Read-only dmesg / journalctl (flag denylist), unconditional
      #
      # +dmesg+ and +journalctl+ read by default; a handful of *flags* mutate
      # (dmesg: buffer wipe +-C+/+-c+, console toggles; journalctl: the
      # +--vacuum-*+ trimmers, +--rotate+/+--flush+, the FSS/catalog writers).
      # The read/mutate split is by flag, not a leading subcommand, so
      # {#read_only_dmesg?}/{#read_only_journalctl?} recover it with a
      # *denylist* ({DMESG_MUTATING_SHORT} / {DMESG_MUTATING_LONG} /
      # {JOURNALCTL_MUTATING_LONG}): approve iff no argument is a mutating flag.
      # Bundled dmesg short options are scanned per character (+-xC+ trips on
      # +C+); a long option's +=value+ tail is stripped before lookup. journalctl
      # has no mutating short option, so a short cluster is read-only data.
      #
      # This is the one deviation from "never auto-approve a destructive
      # command": a denylist's residual is a *future* mutating flag this set
      # doesn't yet name. Accepted because both mutating surfaces are small and
      # stable (util-linux / systemd); an allowlist of read-only flags would
      # close it at the cost of not approving every new read flag — the inferior
      # trade. Same residual shape as the git +--output+ check.
      #
      # == Read-only git (+allow_git:+, opt-in, default off)
      #
      # Everything above is unconditional. +allow_git: true+ additionally
      # approves the read-only git verbs ({READ_ONLY_GIT_SUBCOMMANDS} —
      # +status+/+diff+/+log+/+show+ …, with +--cached+ and friends free, see
      # {#read_only_git?}). Even a bare +git diff+ executes whatever the repo
      # config directs (+core.fsmonitor+, +diff.*.textconv+), so approving it is
      # sound only when that config-execution vector is contained.
      #
      # Containment lives in {Pikuri::Code::Bash}, not here:
      # {Pikuri::Code::Bash::GIT_HARDENING} forces +core.fsmonitor=false+ (and
      # +core.pager=cat+) via the +GIT_CONFIG_*+ environment, overriding a
      # hostile repo-local +.git/config+ — closing the headline vector
      # (+core.fsmonitor = rm -rf ~+, which fires on a plain +git status+). The
      # residual the caller accepts is narrow: diff-driver execution
      # (+diff.external+, a +.gitattributes+-selected +diff.<driver>.command+ /
      # +.textconv+), which the environment can't disable cleanly and we don't
      # rewrite the command to suppress. A plain +git clone+ never copies the
      # remote's config, so that residual is confined to a repo whose
      # +.git/config+ an attacker wrote. +bin/pikuri-code+ gates +allow_git:+
      # behind a startup "trust this repo?" prompt; +pikuri-os+ enables it
      # unconditionally (its agent roams the whole disk — no single repo to
      # vouch for; see +Pikuri::Os::Extension+). Hardening does NOT license
      # *destructive* git, so the verb set excludes every mutating form and
      # {#read_only_git?} additionally refuses inline config / repo-redirection
      # / +--output+.
      #
      # == Residual the allowlist does NOT close
      #
      # PATH hijacking: a bare +ls+ resolves via +$PATH+, so a planted
      # +~/bin/ls+ earlier in +PATH+ runs instead. Planting requires a prior
      # *confirmed* write, and altering +PATH+ in the same command needs
      # +export+/+;+ (metacharacters → not approved), so this is not a
      # one-command bypass. Documented, accepted for v1.
      #
      # == Wiring
      #
      # +Bash.new(command_approver: ReadOnlyCommandApprover.new, …)+ (or
      # +.new(allow_git: true)+). {Bash} passes {#approves?} the raw command
      # string; a non-command tool never consults this predicate, so there's no
      # cross-tool coupling.
      class ReadOnlyCommandApprover
        # Binaries read-only in *every* argument form (no mutating mode
        # reachable, with or without root). See the class header for the
        # curation principle and exclusions.
        #
        # +cd+, +true+, +false+ are shell builtins, not PATH binaries; the
        # classifier only string-matches the first token, so they slot in. +cd+
        # is meaningful only inside a chain (+cd notes && ls+); a bare +cd+
        # approves harmlessly. +true+/+false+ serve the ubiquitous +cmd || true+
        # idiom that swallows a probe's failure (+dpkg -S x || true+) — so the
        # +true+ tail-segment must classify read-only for the chain to approve.
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

        # +systemctl+ subcommands with no mutating form — the only invocations
        # {#read_only_systemctl?} accepts, and the verb must appear immediately
        # after +systemctl+ (so a leading +--root=/x+ is not approved).
        # Excludes every state mutator (+start+/+stop+/+enable+/+mask+/
        # +daemon-reload+ …). These only read; the pager (the one exec vector)
        # spawns solely on a tty, which {Bash}'s piped stdout is not.
        READ_ONLY_SYSTEMCTL_SUBCOMMANDS = Set[
          'list-units', 'list-unit-files', 'list-timers', 'list-sockets',
          'list-jobs', 'list-dependencies', 'status', 'show', 'cat',
          'is-active', 'is-enabled', 'is-failed', 'get-default'
        ].freeze

        # +dpkg+ action flags with no mutating form — must appear immediately
        # after +dpkg+ (so a leading +--admindir+/+--root+ redirection is not
        # approved). +--get-selections+ is the read-side sibling of the excluded
        # +--set-selections+. Excludes every database mutator (+-i+/+-r+/+-P+/
        # +--unpack+/+--configure+/+--set-selections+ …).
        READ_ONLY_DPKG_ACTIONS = Set[
          '-l', '--list', '-L', '--listfiles', '-s', '--status',
          '-S', '--search', '-p', '--print-avail', '--get-selections'
        ].freeze

        # +apt+ subcommands that only query the cache — must appear immediately
        # after +apt+ (so a leading +-o Foo=bar+ config injection is not
        # approved). They run no pre/post-invoke hooks (those fire on the
        # excluded mutating verbs +install+/+remove+/+update+/+upgrade+/…).
        READ_ONLY_APT_SUBCOMMANDS = Set[
          'search', 'show', 'list', 'policy', 'depends', 'rdepends'
        ].freeze

        # git verbs with no mutating form — the only commands {#read_only_git?}
        # accepts (and only under +allow_git:+). Excludes +tag+/+branch+/
        # +remote+/+stash+/+reflog+ (each has a delete/create/expire form) and
        # every working-tree / ref mutator (+checkout+ +reset+ +commit+ +merge+
        # +pull+ +push+ +config+ +gc+ …).
        READ_ONLY_GIT_SUBCOMMANDS = Set[
          'status', 'diff', 'log', 'show', 'blame',
          'rev-parse', 'describe', 'shortlog'
        ].freeze

        # +dmesg+ short-option *letters* that mutate — buffer wipers (+-C+ clear,
        # +-c+ read-clear) and console controls (+-D+ off, +-E+ on, +-n+
        # set-level). {#read_only_dmesg?} scans each cluster char-by-char, so a
        # bundled +-xC+ trips on +C+.
        DMESG_MUTATING_SHORT = Set['C', 'c', 'D', 'E', 'n'].freeze

        # +dmesg+ long options that mutate — the long spellings of
        # {DMESG_MUTATING_SHORT}. {#read_only_dmesg?} strips a +=value+ tail
        # before lookup (+--console-level=1+ matches +--console-level+).
        DMESG_MUTATING_LONG = Set[
          '--clear', '--read-clear', '--console-off', '--console-on',
          '--console-level'
        ].freeze

        # +journalctl+ long options that mutate journal / FSS-key / catalog
        # state — the space-maintenance ops (+--rotate+, +--flush+,
        # +--relinquish-var+, +--smart-relinquish-space+, the +--vacuum-*+
        # trimmers) and the on-disk writers (+--setup-keys+, +--update-catalog+).
        # {#read_only_journalctl?} strips a +=value+ tail before lookup. There's
        # no short companion set — every journalctl maintenance op is long-only.
        JOURNALCTL_MUTATING_LONG = Set[
          '--rotate', '--flush', '--relinquish-var',
          '--smart-relinquish-space',
          '--vacuum-size', '--vacuum-time', '--vacuum-files',
          '--setup-keys', '--update-catalog'
        ].freeze

        # @param allow_git [Boolean] when +true+, additionally approve read-only
        #   git invocations ({#read_only_git?}). Default +false+. Sound only
        #   paired with {Pikuri::Code::Bash::GIT_HARDENING}, which closes the
        #   +core.fsmonitor+ vector; the caller accepts the narrow diff-driver
        #   residual (see the class header).
        def initialize(allow_git: false)
          @allow_git = allow_git
        end

        # @param command [String, nil] the raw bash command string (as {Bash}
        #   received it — no +"$ "+ echo decoration).
        # @return [Boolean] whether every {Tokenizer.tokenize} segment is a
        #   provably read-only simple invocation. A +nil+ parse (more than a
        #   simple chain) or a +nil+/empty command is not approved.
        def approves?(command)
          return false if command.nil?

          command = command.strip
          return false if command.empty?

          segments = Tokenizer.tokenize(command)
          return false if segments.nil?

          segments.all? { |words| segment_read_only?(words) }
        end

        private

        # @param words [Array<String>] one segment's words from {Tokenizer}
        #   (+[]+ for a comment no-op).
        # @return [Boolean] whether the segment is a single bare invocation of a
        #   {READ_ONLY_BINARIES} entry (or a read-only dpkg/apt/systemctl/dmesg/
        #   journalctl query, or under +allow_git:+ a read-only git invocation),
        #   or an empty (comment) segment. A first word containing +/+ is a path
        #   that could point at a planted binary ⇒ not approved.
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

        # @param words [Array<String>] one segment's words.
        # @return [Boolean] whether it is +dpkg+ followed *immediately* by a
        #   {READ_ONLY_DPKG_ACTIONS} flag (so a leading +--admindir+/+--root+
        #   redirection, and every install/remove form, are refused).
        def read_only_dpkg?(words)
          return false unless words[0] == 'dpkg'

          READ_ONLY_DPKG_ACTIONS.include?(words[1])
        end

        # @param words [Array<String>] one segment's words.
        # @return [Boolean] whether it is +apt+ followed *immediately* by a
        #   {READ_ONLY_APT_SUBCOMMANDS} verb (so a leading +-o Foo=bar+ config
        #   injection, and every mutating verb, are refused).
        def read_only_apt?(words)
          return false unless words[0] == 'apt'

          READ_ONLY_APT_SUBCOMMANDS.include?(words[1])
        end

        # @param words [Array<String>] one segment's words.
        # @return [Boolean] whether it is +systemctl+ followed *immediately* by
        #   a {READ_ONLY_SYSTEMCTL_SUBCOMMANDS} verb (so a leading global option
        #   +--root=/x+/+-H host+, and every state mutator, are refused).
        def read_only_systemctl?(words)
          return false unless words[0] == 'systemctl'

          READ_ONLY_SYSTEMCTL_SUBCOMMANDS.include?(words[1])
        end

        # @param words [Array<String>] one segment's words.
        # @return [Boolean] whether it is +dmesg+ with no mutating flag among
        #   its arguments ({DMESG_MUTATING_SHORT} / {DMESG_MUTATING_LONG}).
        def read_only_dmesg?(words)
          return false unless words[0] == 'dmesg'

          words.drop(1).none? { |t| dmesg_mutating_arg?(t) }
        end

        # @param token [String] one +dmesg+ argument.
        # @return [Boolean] whether it names a mutating +dmesg+ flag — a long
        #   option in {DMESG_MUTATING_LONG} (ignoring any +=value+ tail) or a
        #   short cluster containing a {DMESG_MUTATING_SHORT} letter. A bare
        #   value token (no leading +-+) is read-only data ⇒ +false+.
        def dmesg_mutating_arg?(token)
          if token.start_with?('--')
            DMESG_MUTATING_LONG.include?(token.split('=', 2).first)
          elsif token.start_with?('-')
            token[1..].chars.any? { |c| DMESG_MUTATING_SHORT.include?(c) }
          else
            false
          end
        end

        # @param words [Array<String>] one segment's words.
        # @return [Boolean] whether it is +journalctl+ with no mutating flag
        #   among its arguments ({JOURNALCTL_MUTATING_LONG}). Same flag-denylist
        #   shape as {#read_only_dmesg?}.
        def read_only_journalctl?(words)
          return false unless words[0] == 'journalctl'

          words.drop(1).none? { |t| journalctl_mutating_arg?(t) }
        end

        # @param token [String] one +journalctl+ argument.
        # @return [Boolean] whether it names a {JOURNALCTL_MUTATING_LONG} flag
        #   (ignoring any +=value+ tail). A short cluster or bare value token
        #   never mutates ⇒ +false+.
        def journalctl_mutating_arg?(token)
          return false unless token.start_with?('--')

          JOURNALCTL_MUTATING_LONG.include?(token.split('=', 2).first)
        end

        # @param words [Array<String>] one segment's words.
        # @return [Boolean] whether it is +git+ followed *immediately* by a
        #   {READ_ONLY_GIT_SUBCOMMANDS} verb with no +--output+ argument.
        #   Requiring the verb right after +git+ refuses a leading global option
        #   (+-c core.pager=evil+, +-C /other+, +--git-dir+, +--exec-path+) —
        #   the inline-config and repo-redirection escapes — since the second
        #   word then starts with +-+. +--output+ is the one in-tool file writer
        #   in this verb set (+git diff --output=f+). +--cached+/+--staged+/
        #   +--stat+/pathspecs pass free.
        def read_only_git?(words)
          return false unless words[0] == 'git'
          return false unless READ_ONLY_GIT_SUBCOMMANDS.include?(words[1])

          words.drop(2).none? { |t| t.start_with?('--output') }
        end
      end
    end
  end
end
