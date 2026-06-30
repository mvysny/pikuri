# frozen_string_literal: true

require 'pathname'

module Pikuri
  module Os
    # Durable, cross-conversation memory for the OS helper — a single
    # user-owned +MACHINE.md+, the +CLAUDE.md+-for-this-host. Read at boot
    # and folded into the system prompt; the agent updates it through the
    # ordinary (confirmed) +write+/+edit+ tools, and the user can inspect
    # or edit it any time. See +ideas/os-assistant.md+.
    #
    # == Why a markdown file, not mem0
    #
    # This agent reads untrusted local content (logs, downloads), so
    # auto-extracted memory could be poisoned. A markdown file makes that
    # risk *visible + confirmed + reversible* instead of silent: any write
    # is a plain-text diff that goes through the confirmer, and the whole
    # memory is one file the user can read. It also needs no infra — no
    # vector store, no embedder — which fits the "small enough to audit"
    # posture. Edits are picked up on the next prompt assembly (boot or a
    # conversation clear; see "Re-read on each prompt assembly" below).
    #
    # == This class's job
    #
    # Purely the *read* half: resolve the path (XDG), load the content,
    # warn when it grows past {OVERSIZE_BYTES}, and render the
    # system-prompt section. The *write* half is the existing file tools
    # plus a line in the system prompt pointing the agent at {.default_path}
    # — nothing tool-specific lives here.
    #
    # == Re-read on each prompt assembly
    #
    # {#content} reads the file fresh on every call, and the OS extension
    # pulls {#prompt_section} into the system prompt at construction and
    # again on every {Pikuri::Agent#clear_conversation}. So edits to
    # +MACHINE.md+ (by the user or the agent) surface on the next "/clear"
    # — the durable memory stays current across a conversation reset,
    # rather than freezing at boot. The file is small and the read happens
    # only a handful of times (boot + clears), never per turn.
    class MachineMemory
      LOGGER = Pikuri.logger_for('MachineMemory')

      # @return [String] the memory filename.
      FILENAME = 'MACHINE.md'

      # @return [Integer] soft size ceiling. On overshoot we log a warning to
      #   trim — mirrors the Claude CLI nudging an oversized CLAUDE.md.
      #   No hard cap, no eviction: the file is prepended to every prompt,
      #   so a visible nudge is enough.
      OVERSIZE_BYTES = 10 * 1024

      # @return [Pathname] the resolved memory file path.
      attr_reader :path

      # @param path [String, Pathname] memory file location; defaults to
      #   {.default_path}. Overridable for tests.
      def initialize(path: self.class.default_path)
        @path = Pathname.new(path)
      end

      # Host-scoped path under pikuri's XDG config root
      # ({Pikuri::Paths.config} — +$XDG_CONFIG_HOME/pikuri+ or
      # +~/.config/pikuri+). Not project-local: for this agent the machine
      # *and the user's home* are the subject, so the notes span the whole
      # host.
      #
      # @return [String]
      def self.default_path
        Pikuri::Paths.config.join(FILENAME).to_s
      end

      # Raw file content, or +''+ when the file doesn't exist. Read
      # fresh on each call (not memoized) so a re-pull on conversation
      # clear picks up edits; logs the size-guard warning on each read.
      #
      # @return [String]
      def content
        read_content
      end

      # @return [Boolean] whether the content exceeds {OVERSIZE_BYTES}.
      def oversized?
        content.bytesize > OVERSIZE_BYTES
      end

      # The system-prompt section: the notes wrapped in a labeled block
      # naming the file (so the agent knows where its memory lives and can
      # update it), or +nil+ when there's nothing recorded yet — keeping
      # the prompt lean until there's something to say.
      #
      # @return [String, nil]
      def prompt_section
        text = content.strip
        return nil if text.empty?

        <<~SECTION.chomp
          # Notes about this machine

          Durable, user-owned notes about this computer (kept in #{@path}). Treat
          them as trusted context; edit the file to keep the notes current as you
          learn about this computer's setup.

          #{text}
        SECTION
      end

      private

      # @return [String]
      def read_content
        return '' unless @path.file?

        text = @path.read
        if text.bytesize > OVERSIZE_BYTES
          LOGGER.warn(
            "#{@path} is #{text.bytesize / 1024} KB (over the #{OVERSIZE_BYTES / 1024} KB " \
            'guideline); it is prepended to every prompt — consider trimming it.'
          )
        end
        text
      end
    end
  end
end
