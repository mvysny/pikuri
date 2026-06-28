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
      # A command is auto-approved iff ALL hold; otherwise it is delegated
      # to the wrapped confirmer:
      #
      # 1. It contains no shell metacharacter or control byte
      #    ({SHELL_METACHARACTERS}). A pipe, +;+, +&&+, +$(...)+, backtick,
      #    redirect, glob, brace/tilde expansion, quote, or escape means
      #    "more than a single simple invocation" — we do not try to parse
      #    compound shell, we refuse it. (+git st | rm -rf ~+, +$(rm -rf
      #    ~)+, +echo x > /etc/passwd+ all fail here.)
      # 2. The first token is a *bare* command name — no +/+. +./ls+,
      #    +/tmp/ls+, +bin/ls+ are paths that could point at a planted
      #    binary, so they delegate; only PATH-resolved bare names
      #    (+ls+, +cat+, …) qualify.
      # 3. That bare name is on {READ_ONLY_BINARIES}.
      #
      # The failure mode is always "asks the human too often," never
      # "auto-approved something destructive."
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

        # Binaries that are read-only in *every* argument form (no
        # mutating mode reachable, with or without root). See the class
        # header for the curation principle and notable exclusions.
        READ_ONLY_BINARIES = Set[
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
        # @return [Boolean] whether the command is a single, bare,
        #   metacharacter-free invocation of a {READ_ONLY_BINARIES} entry.
        def read_only?(detail)
          return false if detail.nil?

          command = detail.sub(/\A\$ /, '').strip
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
