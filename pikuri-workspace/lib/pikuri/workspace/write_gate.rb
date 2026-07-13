# frozen_string_literal: true

module Pikuri
  module Workspace
    # The shared pre-write gate for the *confirm-all-writes* posture (the
    # OS-helper wiring; the guide's ch7). Before a {Write}/{Edit} mutates a file
    # it runs {.check}, which:
    #
    # 1. **Short-circuits an unwritable target.** If the user can't write the
    #    path, the write would fail anyway and confirming a doomed write is
    #    noise — so return a "permission denied — ask the user to sudo"
    #    observation without prompting. Exact, not a guess: the file tools run
    #    in-process as the real user (only *bash* is sandboxed), so
    #    +File.writable?+ is real. Subsumes +/etc+ / +/boot+ — no path list.
    # 2. **Confirms with a diff.** Else ask the human via a {Confirmer::Change}
    #    payload (the chrome renders the diff), surfacing the decline reason on
    #    no.
    #
    # Stateless module (composition, not a base class); both tools call {.check}
    # and return on a non-nil result. {Write} always routes an overwrite through
    # it (its confirmer is mandatory; +confirm_all_writes+ only decides whether
    # new-file writes go through too); {Edit} stays promptless unless a confirmer
    # is passed, then every edit routes through it.
    module WriteGate
      module_function

      # @param confirmer [Confirmer] the human confirmer.
      # @param path [String] raw path as supplied by the LLM (for messages).
      # @param resolved [Pathname] resolved write target.
      # @param question [String] one-line confirm headline.
      # @param change [Confirmer::Change] the diff payload (old/new bytes).
      # @return [String, nil] an +"Error: ..."+ observation to return
      #   immediately (unwritable, or declined), or +nil+ to proceed.
      def check(confirmer:, path:, resolved:, question:, change:)
        return permission_denied(path) unless writable_target?(resolved)

        case confirmer.ask(request: Confirmer::Request.new(question: question, change: change))
        in Confirmer::Rejected(reason:) then declined(path, reason)
        else nil
        end
      end

      # Whether the user can write the target — the file if it exists, else the
      # nearest existing ancestor dir (where {Write} would +mkdir_p+).
      #
      # @param resolved [Pathname]
      # @return [Boolean]
      def writable_target?(resolved)
        return File.writable?(resolved) if resolved.exist?

        dir = resolved.dirname
        dir = dir.parent until dir.exist? || dir.root?
        File.writable?(dir)
      end

      # @param path [String]
      # @return [String]
      def permission_denied(path)
        "Error: permission denied — cannot write #{path} as this user; " \
          'ask the user to make the change themselves (e.g. with sudo).'
      end

      # @param path [String]
      # @param reason [String, nil] the human's optional decline steering.
      # @return [String]
      def declined(path, reason)
        reason ? "Error: user declined the write to #{path}: #{reason}" \
               : "Error: user declined the write to #{path}."
      end
    end
  end
end
