# frozen_string_literal: true

module Pikuri
  module Workspace
    # Port for resolving a "may I do this?" confirmation to a decision —
    # currently {Pikuri::Code::Bash} (every command), {Write} (overwrite
    # of an existing file with non-identical content) and the +agent+
    # tool's delegation gate. Subclass and implement {#decide}.
    #
    # == The one job: resolve a {Request} to a decision
    #
    # A Confirmer takes a semantic {Request} and returns {Approved} or
    # {Rejected}. That is *all* it does. It carries **no tool policy** and
    # never programmatically classifies the request's *content*: it does
    # not read the filesystem, parse a command, or know what "read-only"
    # means. Two shipped implementations, two ways to resolve:
    #
    # * {Terminal} — the human *chrome*: shows the request to a person and
    #   reads their answer. Lives in +confirmer/terminal.rb+ so the base
    #   seam file stays free of rendering dependencies.
    # * {AutoApprove} — the headless stance: ignores the request entirely
    #   and blanket-approves. This is the +--yolo+ / dev-container posture
    #   ("don't bother me with dialogs"), and because it is
    #   *request-independent* it encodes no policy either.
    #
    # Content classification — e.g. "is this bash command provably
    # read-only, so we can skip the prompt?" — deliberately does **not**
    # live here. It is a tool concern: {Pikuri::Code::Bash} takes a
    # separate +command_approver:+ predicate for exactly that, and only
    # falls through to this confirmer for commands it can't pre-approve.
    # Keeping the two apart is what lets one stateless {Terminal} (or a
    # web/TUI chrome) serve every tool without absorbing any tool's rules.
    #
    # == The return type: {Approved} / {Rejected}
    #
    # {#decide} returns one of exactly two value types — {Approved}
    # (carrying the possibly-edited {Request#detail} to act on) or
    # {Rejected} (carrying an optional human decline reason). Callers
    # dispatch by pattern-matching:
    #
    #   case confirmer.decide(request: request)
    #   in Confirmer::Approved(new_request_detail:) then ...act on it...
    #   in Confirmer::Rejected(reason:)             then ...steer with it...
    #   end
    #
    # {#confirm?} is the derived boolean convenience for the mutation
    # gates ({Write}, {Pikuri::Code::ExitPlanMode}) that need neither the
    # edited payload nor the reason.
    #
    # This richer return carries two orthogonal axes:
    #
    # 1. *Editing (opt-in per request via {Request#editable}).* When the
    #    detail is the verbatim actionable payload — the +agent+ tool's
    #    task string, where +detail == task+ — a confirmer may let the
    #    human *rewrite* it rather than rubber-stamp it: the "human as
    #    author, not approver" shape (see +ideas/more-confirmers.md+ and
    #    +ideas/private-context-taint.md+). Bash's +"$ <command>"+ is a
    #    decorated display string, not a verbatim payload, so it stays
    #    non-editable.
    # 2. *Reason (universal).* Any decline can carry the human's typed
    #    steering ("use the other library") back to the model as the next
    #    observation, turning a bare rejection into direction.
    #
    # The path *not* taken, worth recording so the design space is
    # legible: a +:once+ / +:always+ scope knob. That is a distinct axis —
    # it manages *decision fatigue*, not *authorship or steering* — and it
    # was rejected because the long-term answer to fatigue is making
    # confirmations rare (sandboxing, +--yolo+, the +command_approver+
    # skip), not smarter approval modes. The edit/reason axes added here do
    # not reopen it. (An agentic destructive-or-not classifier remains a
    # deferred v2.)
    #
    # == Seam discipline
    #
    # Tools that need confirmation take a {Confirmer} via constructor and
    # invoke {#decide} with a semantic {Request} — *what* is being asked,
    # never *how* it should look. All presentation belongs to the
    # confirmer implementation: color, the answer cue, answer parsing, the
    # edit affordance, and — security-relevant — neutralizing hostile
    # bytes in LLM-supplied text. The chrome-independent half of that
    # (escape control bytes, flag bidi / zero-width / homoglyph spoofs) is
    # the shared {Pikuri::Sanitizer}; the medium-specific half stays with
    # the renderer that knows its medium (a terminal prints the sanitized
    # text directly; a web client wraps it in HTML-escaping). Tools do
    # *not* call +gets+ / +puts+ directly — same lesson as listeners, keep
    # IO at the seam so a TUI / web client can plug a different
    # implementation in without touching tool code.
    class Confirmer
      # The semantic payload of one confirmation. Three fields:
      #
      # * +question+ — one-line headline composed by the calling tool,
      #   e.g. +"OK to overwrite foo.rb: 120 → 245 bytes?"+. The caller
      #   owns the phrasing and punctuation; the renderer owns the
      #   answer cue (+"(y/n)?"+, buttons, ...).
      # * +detail+ — optional preformatted body, possibly multi-line:
      #   the raw bash command for {Pikuri::Code::Bash}, the task string
      #   for the +agent+ tool, +nil+ for {Write}. Renderers typically
      #   display it monospaced / dimmed. When +editable+ is true this is
      #   the exact text the human may rewrite, and the edited value comes
      #   back as {Approved#new_request_detail}.
      # * +editable+ — whether the human may *edit* +detail+ before
      #   approving (default +false+). Set +true+ only when +detail+ is
      #   the verbatim actionable payload (the +agent+ task), never for a
      #   decorated display string (bash's +"$ <command>"+).
      #
      # +question+ and +detail+ are RAW, straight from tool arguments the
      # LLM composed. Renderers MUST neutralize them before display —
      # route through {Pikuri::Sanitizer} (see {Terminal}), and
      # additionally HTML-escape in a web client.
      Request = Data.define(:question, :detail, :editable, :change) do
        # @param question [String] one-line headline; caller owns phrasing
        # @param detail [String, nil] optional preformatted body / editable payload
        # @param editable [Boolean] whether the human may rewrite +detail+
        # @param change [Change, nil] optional structured file change; when
        #   present a diff-capable chrome renders a diff of it (see {Change}).
        def initialize(question:, detail: nil, editable: false, change: nil)
          super
        end
      end

      # A structured file change for a {Write} / {Edit} confirmation. The
      # tool hands over the *semantic* change — path + old bytes + new
      # bytes — rather than a pre-rendered string, so that rendering the
      # diff stays the confirmer's job (the Confirmer seam: presentation
      # belongs to the chrome). {Terminal} renders a unified diff by
      # shelling to +diff+ (the educational chrome's differ); a richer
      # client (pikuri-tui) renders the same {Change} with its own diff
      # library. +old+ is the current file bytes, or +nil+ for a new file.
      Change = Data.define(:path, :old, :new)

      # An approval. Carries the text to act on: the human-authored
      # (possibly edited) form of {Request#detail} when the request was
      # editable, or +detail+ verbatim otherwise.
      Approved = Data.define(:new_request_detail)

      # A decline. Carries the human's optional steering reason (+nil+
      # when none was given), which the calling tool folds into the
      # observation it hands back to the model.
      Rejected = Data.define(:reason)

      # @param request [Request] semantic content composed by the calling
      #   tool. The confirmer renders it (escaping for its medium), poses
      #   the question, and parses the answer.
      # @return [Approved, Rejected]
      # @raise [NotImplementedError] in the abstract base
      def decide(request:)
        raise NotImplementedError, "#{self.class}#decide must be implemented"
      end

      # Boolean convenience over {#decide} for mutation gates that need
      # neither the edited payload nor the decline reason.
      #
      # @param request [Request]
      # @return [Boolean] +true+ iff approved
      def confirm?(request:)
        decide(request:).is_a?(Approved)
      end

      # Approves everything unedited — the headless "user opted out of
      # dialogs" stance. Because it ignores the request entirely it is
      # request-independent, so it stays a legitimate Confirmer (it
      # classifies nothing). Used by +bin/pikuri-code --yolo+ (docker /
      # dev-container mode), by downstream hosts' own yolo modes (a TUI /
      # web client wires {AUTO_APPROVE} the same way), and by tool specs
      # that don't want to coordinate stdin.
      class AutoApprove < Confirmer
        # @param request [Request]
        # @return [Approved] always, carrying +detail+ unchanged
        def decide(request:)
          Approved.new(new_request_detail: request.detail)
        end
      end

      # Shared singleton instance of {AutoApprove}. Stateless; reusable
      # across tools, sub-agents, and downstream hosts' yolo modes.
      # (There is deliberately no +TERMINAL+ singleton: {Terminal} is a
      # demo chrome, and real front-ends bring their own — construct one
      # with +Terminal.new+ where needed.)
      AUTO_APPROVE = AutoApprove.new
    end
  end
end
