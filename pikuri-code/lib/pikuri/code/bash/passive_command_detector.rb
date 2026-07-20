# frozen_string_literal: true

require 'set'

module Pikuri
  module Code
    class Bash
      # Classifies a bash command as *passive*: {#passive?} is +true+ iff the
      # command provably only **observes** state — it makes no change that
      # persists (disk, device, remote) and sends nothing off the machine. Two
      # clauses, both required: **non-mutating** and **confined**. +cat foo+ is
      # passive (the atime bump is below the line); +rm+ mutates, +git push+ and
      # a +curl+ GET escape the machine, +smartctl -t+ perturbs the device —
      # none are passive.
      #
      # This is a *classifier*, not a decider. {Bash} consults it as its
      # +passive_detector:+ and supplies the meaning: a passive verdict skips the
      # confirmation prompt, everything else falls through to Bash's human
      # {Confirmer}. So +false+ is not a rejection — just "not provably passive,
      # ask the human". The conservative half of the OS-helper's answer to
      # confirmation fatigue: frequent harmless commands (+ls+, +cat+, +grep+,
      # +df+ …) stop prompting while every non-passive command still reaches the
      # human. See +ideas/pikuri-os.md+.
      #
      # It is NOT a {Pikuri::Workspace::Confirmer}: it renders nothing and never
      # resolves a request. Keeping content classification out of the confirmer
      # is deliberate — a Confirmer's one job is to resolve a request, and it
      # must never parse a command. That split also makes +--yolo+ (blanket
      # {Confirmer::AutoApprove}) and passive auto-gating (this predicate)
      # independent, composable axes rather than one tangled decorator.
      #
      # == What "passive" excludes, and what it merely can't prove
      #
      # Two things stay out of the passive set for *different* reasons, and the
      # distinction matters. **Mutation and egress are not passive by
      # definition** — they fail a clause above. **Process execution and
      # privilege escalation are abstained because the prover can't clear them**,
      # not because they are effects: an +exec+ (a spawned +$BROWSER+, +rg
      # --pre+) makes the child's effects *undecidable*, and +sudo+ changes the
      # process's *authority*, not the world. So +sudo dmesg+ is genuinely
      # passive — it only reads; pikuri-os still routes it to the human, but via
      # a *separate* sudo policy, not because this classifier calls it active.
      # Were a vetted sudo-read path ever to exist, it would reuse this verdict
      # unchanged.
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
      # passive. On a successful parse the command is passive iff *every* segment
      # is a provably-passive simple invocation:
      #
      # 1. The first word is a *bare* command name — no +/+. +./ls+, +/tmp/ls+,
      #    +bin/ls+ are paths that could point at a planted binary; only
      #    PATH-resolved bare names (+ls+, +cat+, …) qualify.
      # 2. That bare name is on {PASSIVE_BINARIES} (or the segment is a
      #    passive +dpkg+/+apt+/+apt-cache+/+systemctl+/+file+/+dmesg+/
      #    +journalctl+/+man+/+rg+/+nvme+/+smartctl+ query, or — under
      #    +allow_git:+ — a passive git invocation).
      #
      # A command the strict parse rejects *solely* because of an unquoted glob
      # gets a second look through the {#glob_passive?} fast path (see there):
      # globs are passive, but *only* on pure {PASSIVE_BINARIES} binaries,
      # never the flag-classified families above.
      #
      # The lexing half lives in {Tokenizer}. The consequence here: it hands the
      # classifiers below the *true* de-quoted word (+--clear+, not +--_clear+),
      # which is what makes the denylist / prefix checks sound — a placeholder
      # rewrite would let a quote-smuggled +--''clear+ slip past them. The
      # failure mode is always "asks the human too often", never "called
      # something active passive".
      #
      # == Why a binary allowlist, and why it's short
      #
      # Metacharacter-free is *necessary but not sufficient*: +find . -delete+,
      # +sort -o f+, +systemctl stop x+, +git reset --hard+, +dd+, +tee+,
      # +truncate+, +shred+, +date -s+ are all single, metacharacter-free,
      # *destructive* invocations. So {PASSIVE_BINARIES} holds only binaries
      # with **no mutating or escaping form in any argument** — independent of
      # privilege, so the guarantee doesn't rely on running non-root. That
      # excludes +find+
      # (+-delete+/+-exec+), +env+/+command+ (run other programs),
      # +date+/+hostname+ (set-forms), +xxd+ (a second positional operand is an
      # *output file*: +xxd in out+ writes +out+ — a write with no flag to
      # deny, so it can't be recovered like the others; +od+/+hexdump+ cover
      # read-only hex dumps), and +journalctl+ (recovered by flag denylist
      # below — its read/mutate split is by flag, not subcommand).
      #
      # == Passive subcommand queries (+dpkg+ / +apt+ / +apt-cache+ / +systemctl+), unconditional
      #
      # These are mixed binaries whose query forms are passive but whose mutating
      # forms (+dpkg -i+/+-r+, +apt install+/+remove+, +apt-cache gencaches+,
      # +systemctl start+/+stop+) aren't, so they can't join
      # {PASSIVE_BINARIES} wholesale. {#passive_dpkg?}/{#passive_apt?}/
      # {#passive_apt_cache?}/{#passive_systemctl?} recover the query subset
      # by requiring a known verb *immediately* after the binary
      # ({PASSIVE_DPKG_ACTIONS} / {PASSIVE_APT_SUBCOMMANDS} /
      # {PASSIVE_APT_CACHE_SUBCOMMANDS} / {PASSIVE_SYSTEMCTL_SUBCOMMANDS}) —
      # which refuses a leading redirection or global option (+dpkg
      # --admindir=/x+, +apt -o APT::Foo=bar+, +apt-cache -o Dir::Cache=/x+,
      # +systemctl --root=/x+) since the second token then isn't a query verb.
      #
      # Unlike git these are *unconditional* (no +allow_git:+-style gate): the
      # query forms read state with no command-execution vector — apt's
      # pre/post-invoke hooks fire only on install/update, and +systemctl+
      # spawns its pager only on a tty, which {Bash}'s captured (piped) stdout
      # is not. The pure-query companion +dpkg-query+ has no mutating form at
      # all and sits directly in {PASSIVE_BINARIES} (its +apt-cache+ analogue
      # does not: +gencaches+ writes the cache, hence the subcommand gate).
      #
      # == Passive dmesg / journalctl / man / rg / file (flag denylist), unconditional
      #
      # These read by default; a handful of *flags* mutate or exec. dmesg:
      # buffer wipe +-C+/+-c+, console toggles. journalctl: the +--vacuum-*+
      # trimmers, +--rotate+/+--flush+, the FSS/catalog writers. +man+: +-H+/
      # +--html+ launches +$BROWSER+ (exec *and* egress), +-P+/+--pager+ runs an
      # arbitrary pager. +rg+ (ripgrep): +--pre+ runs an arbitrary preprocessor
      # command per searched file, +--hostname-bin+ one for hyperlink hostnames
      # — both pure exec, so +rg+ can't sit beside +grep+ in
      # {PASSIVE_BINARIES}. +file+: +-C+/+--compile+ writes a +.mgc+ magic
      # file to disk (its lone write form). The read/{mutate,exec} split is by
      # flag, not a leading subcommand, so {#passive_dmesg?}/
      # {#passive_journalctl?}/{#passive_man?}/{#passive_rg?}/
      # {#passive_file?} recover it with a *denylist* ({DMESG_MUTATING_SHORT}
      # / {DMESG_MUTATING_LONG} / {JOURNALCTL_MUTATING_LONG} / {MAN_EXEC_SHORT}
      # / {MAN_EXEC_LONG} / {RG_EXEC_LONG} / {FILE_WRITE_SHORT} /
      # {FILE_WRITE_LONG}): passive iff no argument is a denied flag. Bundled
      # short options are scanned per character (dmesg +-xC+ trips on +C+, man
      # +-aH+ on +H+, file +-zC+ on +C+); a long option's +=value+ tail is
      # stripped before lookup. journalctl and rg have no mutating/exec short
      # option, so a short cluster is passive data (+rg -z+ shells only to
      # fixed-name decompressors, the PATH-hijack residual already covers
      # those). man's and rg's pure-read siblings +apropos+/+whatis+/+grep+
      # have no such flag and sit directly in {PASSIVE_BINARIES}.
      #
      # This is the one deviation from "never call an active command passive":
      # a denylist's residual is a *future* mutating/exec flag this set doesn't
      # yet name. Accepted because the surfaces are small and stable
      # (util-linux / systemd / man-db); an allowlist of passive flags would
      # close it at the cost of not admitting every new read flag — the inferior
      # trade. Same residual shape as the git +--output+ check.
      #
      # == Passive SMART disk diagnostics (+nvme+ / +smartctl+), unconditional
      #
      # Disk-health tools split read/mutate like the families above, and a health
      # check runs their read forms repeatedly (+nvme smart-log+, +smartctl -a+),
      # each otherwise prompting. These need root, so under {Bash}'s unprivileged
      # view they fail +EACCES+ and the model escalates to advising +sudo+ — but
      # the detector classifies *content* (does it mutate?), not *outcome* (will
      # it succeed?), and +smartctl -a+ is passive at every privilege, so it
      # qualifies regardless; auto-approving it just drops a pointless prompt on
      # the way to that honest +EACCES+. See +ideas/bash-confirmer.md+.
      #
      # +nvme+ is subcommand-shaped like +apt+: {#passive_nvme?} accepts a
      # {PASSIVE_NVME_SUBCOMMANDS} verb *immediately* after +nvme+, which
      # refuses the mutators (+format+/+sanitize+/+set-feature+/+fw-download+/
      # +fw-commit+/+reset+) and the +nvme <plugin> <verb>+ form (whose second
      # word is a plugin name, not a known verb). Started deliberately minimal;
      # grow the verb set as real sessions surface further reads.
      #
      # +smartctl+ is flag-shaped, but recovered by a flag *allowlist*, not the
      # denylist the +dmesg+/+man+/+file+ family uses: {#passive_smartctl?}
      # is passive iff *every* +-+-leading argument is a known read flag
      # ({SMARTCTL_READ_SHORT} / {SMARTCTL_READ_LONG}) — a non-flag token is a
      # device path or a flag value, and +smartctl+ only ever mutates via a flag.
      # The allowlist has no residual (an unrecognized flag abstains), so unlike
      # the denylist families this does *not* deviate from "never call an active
      # command passive": +-t+ (self-test), +-s+/+-o+/+-S+/+--set+ (device
      # settings) and +-X+ (abort test) all fall outside the read set. So does
      # *every* +-l+/+--log+ — it is value-sensitive (+-l selective,S-E+ *sets* a
      # test span), so it's lumped out wholesale rather than parsed by value
      # (+-a+/+-x+ already inline the standard error/self-test logs); revisit only
      # if that friction bites.
      #
      # == Passive git (+allow_git:+, opt-in, default off)
      #
      # Everything above is unconditional. +allow_git: true+ additionally treats
      # the passive git verbs ({PASSIVE_GIT_SUBCOMMANDS} —
      # +status+/+diff+/+log+/+show+ …, with +--cached+ and friends free, see
      # {#passive_git?}) as passive. Even a bare +git diff+ executes whatever the
      # repo config directs (+core.fsmonitor+, +diff.*.textconv+) — an *active*
      # vector — so calling it passive is sound only when that config-execution
      # vector is contained.
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
      # {#passive_git?} additionally refuses inline config / repo-redirection
      # / +--output+.
      #
      # == Residual the allowlist does NOT close
      #
      # PATH hijacking: a bare +ls+ resolves via +$PATH+, so a planted
      # +~/bin/ls+ earlier in +PATH+ runs instead. Planting requires a prior
      # *confirmed* write, and altering +PATH+ in the same command needs
      # +export+/+;+ (metacharacters → not passive), so this is not a
      # one-command bypass. Documented, accepted for v1.
      #
      # == Wiring
      #
      # +Bash.new(passive_detector: PassiveCommandDetector.new, …)+ (or
      # +.new(allow_git: true)+). {Bash} passes {#passive?} the raw command
      # string; a non-command tool never consults this predicate, so there's no
      # cross-tool coupling.
      class PassiveCommandDetector
        # Binaries passive in *every* argument form (no mutating mode
        # reachable, with or without root). See the class header for the
        # curation principle and exclusions.
        #
        # +cd+, +true+, +false+ are shell builtins, not PATH binaries; the
        # classifier only string-matches the first token, so they slot in. +cd+
        # is meaningful only inside a chain (+cd notes && ls+); a bare +cd+ is
        # harmlessly passive. +true+/+false+ serve the ubiquitous +cmd || true+
        # idiom that swallows a probe's failure (+dpkg -S x || true+) — so the
        # +true+ tail-segment must classify passive for the whole chain to.
        PASSIVE_BINARIES = Set[
          'cd', 'true', 'false',
          'ls', 'cat', 'tac', 'nl', 'head', 'tail', 'wc',
          'grep', 'egrep', 'fgrep',
          'pwd', 'basename', 'dirname', 'realpath', 'readlink',
          'stat',
          'od', 'hexdump', 'strings',
          'cal',
          'uname', 'arch', 'nproc', 'lscpu', 'lsblk', 'lsusb', 'lspci',
          'df', 'du', 'free', 'vmstat', 'uptime', 'ps',
          'printenv', 'echo', 'printf',
          'whoami', 'id', 'groups',
          'which', 'type',
          'locale', 'getconf',
          'apropos', 'whatis',
          'dpkg-query'
        ].freeze

        # +systemctl+ subcommands with no mutating form — the only invocations
        # {#passive_systemctl?} accepts, and the verb must appear immediately
        # after +systemctl+ (so a leading +--root=/x+ is not passive).
        # Excludes every state mutator (+start+/+stop+/+enable+/+mask+/
        # +daemon-reload+ …). These only read; the pager (the one exec vector)
        # spawns solely on a tty, which {Bash}'s piped stdout is not.
        PASSIVE_SYSTEMCTL_SUBCOMMANDS = Set[
          'list-units', 'list-unit-files', 'list-timers', 'list-sockets',
          'list-jobs', 'list-dependencies', 'status', 'show', 'cat',
          'is-active', 'is-enabled', 'is-failed', 'get-default'
        ].freeze

        # +dpkg+ action flags with no mutating form — must appear immediately
        # after +dpkg+ (so a leading +--admindir+/+--root+ redirection is not
        # passive). +--get-selections+ is the read-side sibling of the excluded
        # +--set-selections+. Excludes every database mutator (+-i+/+-r+/+-P+/
        # +--unpack+/+--configure+/+--set-selections+ …).
        PASSIVE_DPKG_ACTIONS = Set[
          '-l', '--list', '-L', '--listfiles', '-s', '--status',
          '-S', '--search', '-p', '--print-avail', '--get-selections'
        ].freeze

        # +apt+ subcommands that only query the cache — must appear immediately
        # after +apt+ (so a leading +-o Foo=bar+ config injection is not
        # passive). They run no pre/post-invoke hooks (those fire on the
        # excluded mutating verbs +install+/+remove+/+update+/+upgrade+/…).
        PASSIVE_APT_SUBCOMMANDS = Set[
          'search', 'show', 'list', 'policy', 'depends', 'rdepends'
        ].freeze

        # +apt-cache+ subcommands that only read the package cache — must appear
        # immediately after +apt-cache+ (so a leading +-o Dir::Cache=/x+ / +-c
        # file+ config injection is not passive). Excludes +gencaches+, which
        # *builds* (writes) the cache — the one reason +apt-cache+ can't sit in
        # {PASSIVE_BINARIES} wholesale like its pure-query sibling
        # +dpkg-query+.
        PASSIVE_APT_CACHE_SUBCOMMANDS = Set[
          'showpkg', 'showsrc', 'stats', 'dump', 'dumpavail', 'unmet',
          'search', 'show', 'depends', 'rdepends', 'pkgnames', 'policy',
          'madison', 'xvcg', 'dotty'
        ].freeze

        # +nvme+ (nvme-cli) subcommands with no mutating form — the only
        # invocations {#passive_nvme?} accepts, and the verb must appear
        # immediately after +nvme+ (so the +nvme <plugin> <verb>+ form, whose
        # second word is a plugin name, is not passive). Excludes every mutator
        # (+format+/+sanitize+/+set-feature+/+fw-download+/+fw-commit+/+reset+/
        # the +write*+ family). Deliberately minimal — grow as real sessions
        # surface further read verbs.
        PASSIVE_NVME_SUBCOMMANDS = Set[
          'smart-log', 'list', 'id-ctrl', 'id-ns', 'error-log',
          'fw-log', 'get-log', 'get-feature'
        ].freeze

        # git verbs with no mutating form — the only commands {#passive_git?}
        # accepts (and only under +allow_git:+). Excludes +tag+/+branch+/
        # +remote+/+stash+/+reflog+ (each has a delete/create/expire form) and
        # every working-tree / ref mutator (+checkout+ +reset+ +commit+ +merge+
        # +pull+ +push+ +config+ +gc+ …).
        PASSIVE_GIT_SUBCOMMANDS = Set[
          'status', 'diff', 'log', 'show', 'blame',
          'rev-parse', 'describe', 'shortlog'
        ].freeze

        # +dmesg+ short-option *letters* that mutate — buffer wipers (+-C+ clear,
        # +-c+ read-clear) and console controls (+-D+ off, +-E+ on, +-n+
        # set-level). {#passive_dmesg?} scans each cluster char-by-char, so a
        # bundled +-xC+ trips on +C+.
        DMESG_MUTATING_SHORT = Set['C', 'c', 'D', 'E', 'n'].freeze

        # +dmesg+ long options that mutate — the long spellings of
        # {DMESG_MUTATING_SHORT}. {#passive_dmesg?} strips a +=value+ tail
        # before lookup (+--console-level=1+ matches +--console-level+).
        DMESG_MUTATING_LONG = Set[
          '--clear', '--read-clear', '--console-off', '--console-on',
          '--console-level'
        ].freeze

        # +journalctl+ long options that mutate journal / FSS-key / catalog
        # state — the space-maintenance ops (+--rotate+, +--flush+,
        # +--relinquish-var+, +--smart-relinquish-space+, the +--vacuum-*+
        # trimmers) and the on-disk writers (+--setup-keys+, +--update-catalog+).
        # {#passive_journalctl?} strips a +=value+ tail before lookup. There's
        # no short companion set — every journalctl maintenance op is long-only.
        JOURNALCTL_MUTATING_LONG = Set[
          '--rotate', '--flush', '--relinquish-var',
          '--smart-relinquish-space',
          '--vacuum-size', '--vacuum-time', '--vacuum-files',
          '--setup-keys', '--update-catalog'
        ].freeze

        # +man+ short-option *letters* that spawn a program — +-H+ (render to
        # HTML and launch +$BROWSER+: exec *and* egress) and +-P+ (run an
        # arbitrary pager). {#passive_man?} scans each cluster char-by-char,
        # so a bundled +-aH+ trips on +H+.
        MAN_EXEC_SHORT = Set['H', 'P'].freeze

        # +man+ long options that spawn a program — the long spellings of
        # {MAN_EXEC_SHORT}. {#passive_man?} strips a +=value+ tail before
        # lookup (+--pager=less+ matches +--pager+).
        MAN_EXEC_LONG = Set['--html', '--pager'].freeze

        # +rg+ (ripgrep) long options that run an arbitrary command — +--pre+
        # (a preprocessor executed per searched file) and +--hostname-bin+ (run
        # to resolve the hostname for hyperlinks). Both are pure exec vectors,
        # which is why +rg+ can't sit beside +grep+ in {PASSIVE_BINARIES}.
        # {#passive_rg?} strips a +=value+ tail before lookup
        # (+--pre=/bin/sh+ matches +--pre+). rg has no *short* exec option, so
        # a short cluster is passive data — no per-character scan needed
        # (+-z+/+--search-zip+ shells only to fixed-name decompressors, already
        # covered by the PATH-hijack residual, so it stays passive).
        RG_EXEC_LONG = Set['--pre', '--hostname-bin'].freeze

        # +file+ short-option *letters* that write — +-C+ compiles the magic
        # file to a +.mgc+ on disk. {#passive_file?} scans each cluster
        # char-by-char, so a bundled +-zC+ trips on +C+. This is +file+'s only
        # mutating form; every other flag (+-i+, +-L+, +-s+, +-m magicfile+ …)
        # reads.
        FILE_WRITE_SHORT = Set['C'].freeze

        # +file+ long options that write — the long spelling of
        # {FILE_WRITE_SHORT}. {#passive_file?} strips a +=value+ tail before
        # lookup.
        FILE_WRITE_LONG = Set['--compile'].freeze

        # +smartctl+ short-option *letters* that only read — SMART data (+-a+
        # all, +-x+ xall, +-A+ attributes), device info (+-i+), health (+-H+),
        # capabilities (+-c+), plus the device-type modifier +-d+ (its +TYPE+
        # value is a separate token). {#passive_smartctl?} is passive iff every
        # letter in a +-+-cluster is here — an allowlist, so a mutating letter
        # (+-t+/+-s+/+-o+/+-S+/+-X+) or the value-sensitive +-l+ simply isn't
        # listed and abstains.
        SMARTCTL_READ_SHORT = Set['a', 'x', 'i', 'H', 'c', 'A', 'd'].freeze

        # +smartctl+ long options that only read — the long spellings of
        # {SMARTCTL_READ_SHORT} (+--device+ carries the +-d+ modifier).
        # {#passive_smartctl?} strips a +=value+ tail before lookup
        # (+--device=sat+ matches +--device+).
        SMARTCTL_READ_LONG = Set[
          '--all', '--xall', '--info', '--health',
          '--capabilities', '--attributes', '--device'
        ].freeze

        # @param allow_git [Boolean] when +true+, additionally accept passive
        #   git invocations ({#passive_git?}). Default +false+. Sound only
        #   paired with {Pikuri::Code::Bash::GIT_HARDENING}, which closes the
        #   +core.fsmonitor+ vector; the caller accepts the narrow diff-driver
        #   residual (see the class header).
        def initialize(allow_git: false)
          @allow_git = allow_git
        end

        # @param command [String, nil] the raw bash command string (as {Bash}
        #   received it — no +"$ "+ echo decoration).
        # @return [Boolean] whether every {Tokenizer.tokenize} segment is a
        #   provably passive simple invocation. A +nil+ parse (more than a
        #   simple chain) or a +nil+/empty command is not passive.
        def passive?(command)
          return false if command.nil?

          command = command.strip
          return false if command.empty?

          segments = Tokenizer.tokenize(command)
          return segments.all? { |words| segment_passive?(words) } unless segments.nil?

          # The strict parse rejected it. If its *only* complication is an
          # unquoted glob, the glob fast path may still deem it passive.
          glob_passive?(command)
        end

        private

        # The pure-allowlist glob fast path: re-parse with globs kept literal
        # ({Tokenizer.tokenize} +allow_glob:+) and pass iff every segment is
        # a bare {PASSIVE_BINARIES} invocation.
        #
        #   ls *.txt | wc -l      # passive: every binary passive in any arg
        #   dmesg *               # NOT passive: dmesg isn't pure-allowlist
        #
        # Sound because a glob is expanded by bash *after* this check, and a
        # {PASSIVE_BINARIES} command has no mutating/exec/output-file form in
        # *any* argument — so a glob that expands to a +-flag+-looking filename
        # (or any filename) can't grow teeth. The recovered families
        # (dpkg/apt/dmesg/journalctl/man/rg/file/nvme/smartctl/git) are
        # deliberately *not*
        # eligible: they classify by flag *spelling*, which a post-expansion
        # glob would defeat (a planted +-C+/+--pre+ file smuggled past the
        # denylist) — so any glob on them keeps delegating to the human. The
        # +allow_glob+ re-parse still rejects every non-glob complication ($()
        # substitution, a real redirect, an unbalanced quote …), so only a
        # command whose sole sin was an unquoted glob reaches the check.
        #
        # @param command [String] the stripped command (strict parse already
        #   returned +nil+).
        # @return [Boolean] whether every glob-tolerant segment is a bare
        #   pure-allowlist invocation.
        def glob_passive?(command)
          segments = Tokenizer.tokenize(command, allow_glob: true)
          return false if segments.nil?

          segments.all? { |words| glob_safe_binary?(words) }
        end

        # @param words [Array<String>] one glob-tolerant segment's words.
        # @return [Boolean] whether it is a single bare {PASSIVE_BINARIES}
        #   invocation (or an empty comment segment). Unlike {#segment_passive?}
        #   this admits *only* the pure allowlist — no dpkg/dmesg/git recovery —
        #   because those can't be classified once a glob may expand into their
        #   flags. A first word with +/+ or one that is itself a glob is not in
        #   {PASSIVE_BINARIES} ⇒ not passive.
        def glob_safe_binary?(words)
          return true if words.empty?

          first = words.first
          !first.include?('/') && PASSIVE_BINARIES.include?(first)
        end

        # @param words [Array<String>] one segment's words from {Tokenizer}
        #   (+[]+ for a comment no-op).
        # @return [Boolean] whether the segment is a single bare invocation of a
        #   {PASSIVE_BINARIES} entry (or a passive dpkg/apt/apt-cache/systemctl/
        #   file/dmesg/journalctl/man/rg/nvme/smartctl query, or under +allow_git:+
        #   a passive git invocation),
        #   or an empty (comment) segment. A first word containing +/+ is a path
        #   that could point at a planted binary ⇒ not passive.
        def segment_passive?(words)
          return true if words.empty?

          first = words.first
          return false if first.include?('/')
          return true if PASSIVE_BINARIES.include?(first)
          return true if passive_dpkg?(words)
          return true if passive_apt?(words)
          return true if passive_apt_cache?(words)
          return true if passive_systemctl?(words)
          return true if passive_file?(words)
          return true if passive_dmesg?(words)
          return true if passive_journalctl?(words)
          return true if passive_man?(words)
          return true if passive_rg?(words)
          return true if passive_nvme?(words)
          return true if passive_smartctl?(words)

          @allow_git && passive_git?(words)
        end

        # @param words [Array<String>] one segment's words.
        # @return [Boolean] whether it is +dpkg+ followed *immediately* by a
        #   {PASSIVE_DPKG_ACTIONS} flag (so a leading +--admindir+/+--root+
        #   redirection, and every install/remove form, are refused).
        def passive_dpkg?(words)
          return false unless words[0] == 'dpkg'

          PASSIVE_DPKG_ACTIONS.include?(words[1])
        end

        # @param words [Array<String>] one segment's words.
        # @return [Boolean] whether it is +apt+ followed *immediately* by a
        #   {PASSIVE_APT_SUBCOMMANDS} verb (so a leading +-o Foo=bar+ config
        #   injection, and every mutating verb, are refused).
        def passive_apt?(words)
          return false unless words[0] == 'apt'

          PASSIVE_APT_SUBCOMMANDS.include?(words[1])
        end

        # @param words [Array<String>] one segment's words.
        # @return [Boolean] whether it is +apt-cache+ followed *immediately* by a
        #   {PASSIVE_APT_CACHE_SUBCOMMANDS} verb (so a leading +-o Dir::Cache=/x+
        #   config injection, and the cache-building +gencaches+, are refused).
        def passive_apt_cache?(words)
          return false unless words[0] == 'apt-cache'

          PASSIVE_APT_CACHE_SUBCOMMANDS.include?(words[1])
        end

        # @param words [Array<String>] one segment's words.
        # @return [Boolean] whether it is +systemctl+ followed *immediately* by
        #   a {PASSIVE_SYSTEMCTL_SUBCOMMANDS} verb (so a leading global option
        #   +--root=/x+/+-H host+, and every state mutator, are refused).
        def passive_systemctl?(words)
          return false unless words[0] == 'systemctl'

          PASSIVE_SYSTEMCTL_SUBCOMMANDS.include?(words[1])
        end

        # @param words [Array<String>] one segment's words.
        # @return [Boolean] whether it is +dmesg+ with no mutating flag among
        #   its arguments ({DMESG_MUTATING_SHORT} / {DMESG_MUTATING_LONG}).
        def passive_dmesg?(words)
          return false unless words[0] == 'dmesg'

          words.drop(1).none? { |t| dmesg_mutating_arg?(t) }
        end

        # @param token [String] one +dmesg+ argument.
        # @return [Boolean] whether it names a mutating +dmesg+ flag — a long
        #   option in {DMESG_MUTATING_LONG} (ignoring any +=value+ tail) or a
        #   short cluster containing a {DMESG_MUTATING_SHORT} letter. A bare
        #   value token (no leading +-+) is passive data ⇒ +false+.
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
        #   shape as {#passive_dmesg?}.
        def passive_journalctl?(words)
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
        # @return [Boolean] whether it is +man+ with no program-spawning flag
        #   among its arguments ({MAN_EXEC_SHORT} / {MAN_EXEC_LONG}). Same
        #   flag-denylist shape as {#passive_dmesg?}, but the residual it
        #   guards is *exec/egress*, not mutation. The pure-read man-suite
        #   siblings +apropos+/+whatis+ have no such flag and sit directly in
        #   {PASSIVE_BINARIES}.
        def passive_man?(words)
          return false unless words[0] == 'man'

          words.drop(1).none? { |t| man_exec_arg?(t) }
        end

        # @param token [String] one +man+ argument.
        # @return [Boolean] whether it names a program-spawning +man+ flag — a
        #   long option in {MAN_EXEC_LONG} (ignoring any +=value+ tail) or a
        #   short cluster containing a {MAN_EXEC_SHORT} letter. A bare value
        #   token (no leading +-+) is passive data ⇒ +false+.
        def man_exec_arg?(token)
          if token.start_with?('--')
            MAN_EXEC_LONG.include?(token.split('=', 2).first)
          elsif token.start_with?('-')
            token[1..].chars.any? { |c| MAN_EXEC_SHORT.include?(c) }
          else
            false
          end
        end

        # @param words [Array<String>] one segment's words.
        # @return [Boolean] whether it is +rg+ with no arbitrary-command flag
        #   among its arguments ({RG_EXEC_LONG}). Same flag-denylist shape as
        #   {#passive_man?}, but rg's exec flags are long-only so there's no
        #   short-cluster scan. Residual: rg also reads +--pre+ from a config
        #   file named by +$RIPGREP_CONFIG_PATH+, which this can't see — but
        #   setting that env already presupposes control of the agent's
        #   environment, the same class as the PATH-hijack residual.
        def passive_rg?(words)
          return false unless words[0] == 'rg'

          words.drop(1).none? { |t| rg_exec_arg?(t) }
        end

        # @param token [String] one +rg+ argument.
        # @return [Boolean] whether it names a {RG_EXEC_LONG} flag (ignoring any
        #   +=value+ tail). A short cluster or bare value token never execs ⇒
        #   +false+.
        def rg_exec_arg?(token)
          return false unless token.start_with?('--')

          RG_EXEC_LONG.include?(token.split('=', 2).first)
        end

        # @param words [Array<String>] one segment's words.
        # @return [Boolean] whether it is +file+ with no writing flag among its
        #   arguments ({FILE_WRITE_SHORT} / {FILE_WRITE_LONG}). Same flag-denylist
        #   shape as {#passive_man?}.
        def passive_file?(words)
          return false unless words[0] == 'file'

          words.drop(1).none? { |t| file_write_arg?(t) }
        end

        # @param token [String] one +file+ argument.
        # @return [Boolean] whether it names a writing +file+ flag — a long
        #   option in {FILE_WRITE_LONG} (ignoring any +=value+ tail) or a short
        #   cluster containing a {FILE_WRITE_SHORT} letter. A bare value token
        #   (no leading +-+) is passive data ⇒ +false+.
        def file_write_arg?(token)
          if token.start_with?('--')
            FILE_WRITE_LONG.include?(token.split('=', 2).first)
          elsif token.start_with?('-')
            token[1..].chars.any? { |c| FILE_WRITE_SHORT.include?(c) }
          else
            false
          end
        end

        # @param words [Array<String>] one segment's words.
        # @return [Boolean] whether it is +nvme+ followed *immediately* by a
        #   {PASSIVE_NVME_SUBCOMMANDS} verb (so the +nvme <plugin> <verb>+ form
        #   and every mutating verb are refused).
        def passive_nvme?(words)
          return false unless words[0] == 'nvme'

          PASSIVE_NVME_SUBCOMMANDS.include?(words[1])
        end

        # @param words [Array<String>] one segment's words.
        # @return [Boolean] whether it is +smartctl+ with *every* +-+-leading
        #   argument a known read flag ({SMARTCTL_READ_SHORT} /
        #   {SMARTCTL_READ_LONG}). A flag *allowlist* (inverse polarity of the
        #   dmesg/man/file denylists): an unrecognized flag ⇒ not passive, so
        #   the mutating and value-sensitive forms abstain with no enumeration.
        #   A non-flag token is a device path or a flag value (+-d sat+) and is
        #   always safe — +smartctl+ mutates only via a flag.
        def passive_smartctl?(words)
          return false unless words[0] == 'smartctl'

          words.drop(1).all? { |t| smartctl_read_arg?(t) }
        end

        # @param token [String] one +smartctl+ argument.
        # @return [Boolean] whether it is a read-only argument — a long option in
        #   {SMARTCTL_READ_LONG} (ignoring any +=value+ tail), a short cluster
        #   whose every letter is in {SMARTCTL_READ_SHORT}, or a bare non-flag
        #   token (device path / flag value). A bundled cluster mixing in an
        #   unlisted letter (+-at+) ⇒ +false+ ⇒ abstain — the safe direction.
        def smartctl_read_arg?(token)
          if token.start_with?('--')
            SMARTCTL_READ_LONG.include?(token.split('=', 2).first)
          elsif token.start_with?('-')
            token[1..].chars.all? { |c| SMARTCTL_READ_SHORT.include?(c) }
          else
            true
          end
        end

        # @param words [Array<String>] one segment's words.
        # @return [Boolean] whether it is +git+ followed *immediately* by a
        #   {PASSIVE_GIT_SUBCOMMANDS} verb with no +--output+ argument.
        #   Requiring the verb right after +git+ refuses a leading global option
        #   (+-c core.pager=evil+, +-C /other+, +--git-dir+, +--exec-path+) —
        #   the inline-config and repo-redirection escapes — since the second
        #   word then starts with +-+. +--output+ is the one in-tool file writer
        #   in this verb set (+git diff --output=f+). +--cached+/+--staged+/
        #   +--stat+/pathspecs pass free.
        def passive_git?(words)
          return false unless words[0] == 'git'
          return false unless PASSIVE_GIT_SUBCOMMANDS.include?(words[1])

          words.drop(2).none? { |t| t.start_with?('--output') }
        end
      end
    end
  end
end
