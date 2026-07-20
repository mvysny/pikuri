# frozen_string_literal: true

module Pikuri
  module Workspace
    # Port for resolving a "may I do this?" confirmation to a decision —
    # currently {Pikuri::Code::Bash}, {Write}, and the +agent+ tool's
    # delegation gate. Subclass and implement {#ask}.
    #
    # == The one job: resolve a {Request} to a decision
    #
    # A Confirmer takes a semantic {Request} and returns {Approved} or
    # {Rejected}. That is *all*: it carries **no tool policy** and never
    # classifies the request's *content* (no filesystem reads, no command
    # parsing, no notion of "passive"). Two shipped implementations:
    #
    # * {Terminal} — the human *chrome*: shows the request and reads the answer.
    #   In +confirmer/terminal.rb+ so this seam file stays free of rendering deps.
    # * {AutoApprove} — the headless stance: ignores the request and
    #   blanket-approves (+--yolo+ / dev-container). Request-independent, so it
    #   encodes no policy either.
    #
    # Content classification ("is this bash command provably passive, skip the
    # prompt?") deliberately does *not* live here — it's a tool concern
    # ({Pikuri::Code::Bash} takes a separate +passive_detector:+ predicate,
    # falling through to this confirmer only for commands it can't pre-approve).
    # Keeping them apart lets one stateless chrome serve every tool.
    #
    # == The return type: {Approved} / {Rejected}
    #
    # {#ask} returns {Approved} (the possibly-edited {Request#detail} to act on)
    # or {Rejected} (an optional decline reason); callers pattern-match:
    #
    #   case confirmer.ask(request: request)
    #   in Confirmer::Approved(new_request_detail:) then ...act on it...
    #   in Confirmer::Rejected(reason:)             then ...steer with it...
    #   end
    #
    # {#confirm?} is the derived boolean convenience for gates ({Write},
    # {Pikuri::Code::ExitPlanMode}) needing neither the payload nor the reason.
    # Two orthogonal axes ride the richer return:
    #
    # 1. *Editing* (opt-in via {Request#editable}) — when +detail+ is the
    #    verbatim actionable payload (the +agent+ task, where +detail == task+),
    #    a confirmer may let the human *rewrite* it — "human as author, not
    #    approver". Bash's +"$ <command>"+ is a decorated display string, so it
    #    stays non-editable.
    # 2. *Reason* (universal) — any decline can carry typed steering ("use the
    #    other library") back to the model as the next observation.
    #
    # A +:once+/+:always+ scope knob was *rejected*: it manages decision
    # *fatigue*, a distinct axis, and the long-term answer to fatigue is making
    # confirmations rare (sandboxing, +--yolo+, the +passive_detector+ skip),
    # not smarter approval modes. (An agentic destructive-or-not classifier is a
    # deferred v2.)
    #
    # == Seam discipline
    #
    # Tools take a {Confirmer} via constructor and invoke {#ask} with a semantic
    # {Request} — *what* is asked, never *how* it looks. All presentation
    # belongs to the confirmer: color, the answer cue, parsing, the edit
    # affordance, and — security-relevant — neutralizing hostile bytes in
    # LLM-supplied text. The chrome-independent half (escape control bytes, flag
    # bidi/zero-width/homoglyph spoofs) is the shared {Pikuri::Sanitizer}; the
    # medium-specific half stays with the renderer (a terminal prints sanitized
    # text; a web client HTML-escapes). Tools never call +gets+/+puts+ directly
    # — keep IO at the seam so a TUI/web client plugs in without touching tools.
    class Confirmer
      # The semantic payload of one confirmation:
      #
      # * +question+ — one-line headline the tool composes (e.g. +"OK to
      #   overwrite foo.rb: 120 → 245 bytes?"+); the caller owns phrasing, the
      #   renderer owns the answer cue.
      # * +detail+ — optional preformatted body: the raw bash command, the
      #   +agent+ task, +nil+ for {Write}. When +editable+, the exact text the
      #   human may rewrite, returned as {Approved#new_request_detail}.
      # * +editable+ — whether the human may edit +detail+ (default +false+);
      #   +true+ only when +detail+ is the verbatim payload (the +agent+ task),
      #   never a decorated string (bash's +"$ <command>"+).
      #
      # +question+/+detail+ are RAW LLM-composed text — renderers MUST neutralize
      # them via {Pikuri::Sanitizer} (see {Terminal}), plus HTML-escape in a web
      # client.
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

      # A structured file change for a {Write}/{Edit} confirmation: the
      # *semantic* change (path + old bytes + new bytes), not a pre-rendered
      # string, so diff rendering stays the confirmer's job. {Terminal} shells
      # to +diff+; a richer client renders the same {Change} its own way. +old+
      # is the current bytes, or +nil+ for a new file.
      Change = Data.define(:path, :old, :new)

      # An approval carrying the text to act on: the human-authored (possibly
      # edited) {Request#detail} when editable, else +detail+ verbatim.
      Approved = Data.define(:new_request_detail)

      # A decline carrying the human's optional steering reason (+nil+ if none),
      # which the tool folds into the observation handed back to the model.
      Rejected = Data.define(:reason)

      # @param request [Request] semantic content composed by the calling
      #   tool. The confirmer renders it (escaping for its medium), poses
      #   the question, and parses the answer.
      # @return [Approved, Rejected]
      # @raise [NotImplementedError] in the abstract base
      def ask(request:)
        raise NotImplementedError, "#{self.class}#ask must be implemented"
      end

      # Boolean convenience over {#ask} for gates needing neither the edited
      # payload nor the reason.
      #
      # @param request [Request]
      # @return [Boolean] +true+ iff approved
      def confirm?(request:)
        ask(request:).is_a?(Approved)
      end

      # Approves everything unedited — the headless "opted out of dialogs"
      # stance. Request-independent, so it classifies nothing and stays a
      # legitimate Confirmer. Used by +bin/pikuri-code --yolo+, downstream hosts'
      # yolo modes, and specs that don't want to coordinate stdin.
      class AutoApprove < Confirmer
        # @param request [Request]
        # @return [Approved] always, carrying +detail+ unchanged
        def ask(request:)
          Approved.new(new_request_detail: request.detail)
        end
      end

      # Shared stateless {AutoApprove} singleton, reusable across tools,
      # sub-agents, and hosts' yolo modes. (No +TERMINAL+ singleton: {Terminal}
      # is a demo chrome, and real front-ends bring their own.)
      AUTO_APPROVE = AutoApprove.new
    end
  end
end
