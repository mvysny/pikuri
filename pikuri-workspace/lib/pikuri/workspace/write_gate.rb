# frozen_string_literal: true

module Pikuri
  module Workspace
    # The shared pre-write gate behind every confirmed write
    # (book/touching-files.md). Before a {Write}/{Edit} mutates a file it runs
    # {.check}, which:
    #
    # 1. **Short-circuits an unwritable target.** If the user can't write the
    #    path, the write would fail anyway and confirming a doomed write is
    #    noise — so return a "permission denied — ask the user to sudo"
    #    observation without prompting. Exact, not a guess: the file tools run
    #    in-process as the real user (only *bash* is sandboxed), so
    #    +File.writable?+ is real. Subsumes +/etc+ / +/boot+ — no path list.
    # 2. **Confirms with a diff.** Else ask the human via a {Confirmer::Change}
    #    payload (the chrome renders the diff); a decline answers with the
    #    decision's own observation.
    #
    # Stateless module (composition, not a base class); both tools call {.check}
    # and return on a non-nil result. {Write} always routes an overwrite through
    # it; +confirm_all_writes: false+ lets a new file skip it and makes {Edit}
    # skip it entirely.
    #
    # If a frequent-writing agent ever wants some writes to skip the prompt,
    # grow an allowlist of safe paths (deny-by-default = confirm, like
    # +PASSIVE_BINARIES+), never a denylist of sensitive ones — the denylist
    # loses the enumeration game. Confirming every write is that allowlist,
    # empty.
    module WriteGate
      module_function

      # @param confirmer [Confirmer] the human confirmer.
      # @param path [String] raw path as supplied by the LLM (for messages).
      # @param resolved [Pathname] resolved write target.
      # @param question [String] one-line confirm headline.
      # @param change [Confirmer::Change] the diff payload (old/new bytes).
      # @param cancellable [Pikuri::Agent::Control::Cancellable] the calling
      #   turn's token, for {Confirmer#ask}.
      # @return [Pikuri::Tool::Result, nil] the observation to return at once
      #   (unwritable, rejected or redirected), or +nil+ to proceed.
      # @raise [Pikuri::Agent::Control::Cancellable::Cancelled] when the turn
      #   is cancelled while the question waits.
      def check(confirmer:, path:, resolved:, question:, change:, cancellable:)
        return permission_denied(path) unless writable_target?(resolved)

        case decision = confirmer.ask(request: Confirmer::Request.new(question: question, change: change),
                                      cancellable: cancellable)
        in Confirmer::Approved then nil
        in Confirmer::Rejected | Confirmer::Redirected then decision.observation("the write to #{path}")
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
      # @return [Pikuri::Tool::Result]
      def permission_denied(path)
        Pikuri::Tool::Result.error("permission denied — cannot write #{path} as this user; " \
                                   'ask the user to make the change themselves (e.g. with sudo).')
      end
    end
  end
end
