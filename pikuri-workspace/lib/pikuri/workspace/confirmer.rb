# frozen_string_literal: true

module Pikuri
  module Workspace
    # Port for resolving a "may I do this?" confirmation to a decision —
    # currently {Pikuri::Code::Bash}, {Write}, and the +agent+ tool's
    # delegation gate. Subclass and implement {#ask}.
    #
    # == The one job: resolve a {Request} to a decision
    #
    # A Confirmer takes a semantic {Request} and returns {Approved},
    # {Rejected} or {Redirected}. That is *all*: it carries **no tool policy** and never
    # classifies the request's *content* (no filesystem reads, no command
    # parsing, no notion of "passive"). Two shipped implementations:
    #
    # * {Terminal} — the human *chrome*: shows the request and reads the answer.
    #   In +confirmer/terminal.rb+ so this seam file stays free of rendering deps.
    #   Written for pikuri's own single-threaded +bin/+ scripts and best read as
    #   the worked example — a TUI or web host implements this seam itself.
    # * {AutoApprove} — the headless stance: ignores the request and
    #   blanket-approves (+--yolo+ / dev-container). Request-independent, so it
    #   encodes no policy either.
    #
    # Sharing is per implementation, and the two shipped ones differ:
    # {AutoApprove} is +P_stateless+ and shares freely, while {Terminal} is
    # +P_one_agent+ because concurrent agents fight over one human's keystrokes.
    # A confirmer written for a multi-agent host owns that queueing — and owns
    # naming which agent is asking, which is why the queue can't usefully live
    # down here.
    #
    # Content classification ("is this bash command provably passive, skip the
    # prompt?") deliberately does *not* live here — it's a tool concern
    # ({Pikuri::Code::Bash} takes a separate +passive_detector:+ predicate,
    # falling through to this confirmer only for commands it can't pre-approve).
    # Keeping them apart lets one stateless chrome serve every tool.
    #
    # == The return type: {Approved} / {Rejected} / {Redirected}
    #
    # The human's gesture picks one of three; callers pattern-match, and a
    # decline answers the model through the decision's own {Rejected#observation}
    # / {Redirected#observation}:
    #
    #   case decision = confirmer.ask(request: request)
    #   in Confirmer::Approved(new_request_detail:) then ...act on it...
    #   in Confirmer::Rejected | Confirmer::Redirected
    #     return decision.observation('the bash command')
    #   end
    #
    # * {Approved} — approve, carrying the possibly-edited {Request#detail}.
    # * {Rejected} — a plain "no": final for this action, the model stops.
    # * {Redirected} — the human typed words ("make it Wednesday", "too
    #   risky"): the model follows them, and may propose again — which asks again.
    #
    # Editing is opt-in via {Request#editable}: when +detail+ is the verbatim
    # actionable payload (the +agent+ task), a confirmer may let the human
    # *rewrite* it — "human as author, not approver". Bash's +"$ <command>"+ is
    # a decorated display string, so it stays non-editable.
    #
    # {#confirm?} is the boolean convenience for a gate that has nothing to tell
    # the model — it reads a {Redirected} as a plain no and drops the words.
    #
    # == Cancelling a parked ask
    #
    # A host whose cancel key (Escape, Ctrl+C) can fire while {#ask} waits
    # should call +cancel!+ on the turn's {Pikuri::Agent::Control::Cancellable}
    # and make the parked {#ask} raise
    # {Pikuri::Agent::Control::Cancellable::Cancelled}: the tool lets it
    # through, the agent ends the turn, and the stranded call is answered
    # +[Cancelled by the user]+ — the same path a cancelled
    # {Pikuri::Agent::Control::Cancellable#sleep} takes. Answering {Rejected}
    # instead is not a cancel: the turn runs on for one more model reply.
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

      # A plain "no", final for this action. It carries no text on purpose:
      # the model sees only the observation, and any words after "declined"
      # read as a hint to work around — every typed word is a {Redirected}.
      # See +D_bare_rejected+.
      Rejected = Data.define do
        # The tool's answer to the model, telling it to stop:
        #
        #   Rejected.new.observation('the write to a.txt').content
        #   # => "Error: user declined the write to a.txt. Don't retry it or reach the
        #   #    same end another way; tell the user you stopped."
        #
        # @param action [String] what was declined, as a noun phrase
        # @return [Pikuri::Tool::Result] an error result
        def observation(action)
          Pikuri::Tool::Result.error("user declined #{action}. Don't retry it or reach " \
                                     'the same end another way; tell the user you stopped.')
        end
      end

      # A decline carrying the words the human typed — a different way, or why
      # not. The model follows them, and may propose again.
      Redirected = Data.define(:message) do
        # The tool's answer to the model, quoting the human — deliberately not
        # an error, which would read as a failure to recover from:
        #
        #   Redirected.new(message: 'use vim').observation('the write to a.txt').content
        #   # => "The user declined the write to a.txt and said: use vim"
        #
        # @param action [String] what was declined, as a noun phrase
        # @return [Pikuri::Tool::Result]
        def observation(action)
          Pikuri::Tool::Result.new(content: "The user declined #{action} and said: #{message}",
                                   summary: 'Redirected by the user')
        end
      end

      # @param request [Request] semantic content composed by the calling
      #   tool. The confirmer renders it (escaping for its medium), poses
      #   the question, and parses the answer.
      # @return [Approved, Rejected, Redirected]
      # @raise [NotImplementedError] in the abstract base
      # @raise [Pikuri::Agent::Control::Cancellable::Cancelled] when the host
      #   cancels the turn while the question waits — see "Cancelling a parked
      #   ask" above
      def ask(request:)
        raise NotImplementedError, "#{self.class}#ask must be implemented"
      end

      # Boolean convenience over {#ask}, for a question whose answer goes
      # nowhere near the model (a {Redirected}'s words are dropped).
      #
      # @param request [Request]
      # @return [Boolean] +true+ iff approved
      def confirm?(request:)
        ask(request:).is_a?(Approved)
      end

      # Whether {#ask} can actually stop and wait for a person — the posture
      # {Pikuri::Trifecta} reads when deciding whether a gated tool reaches the
      # approver seat rather than counting as autonomous egress.
      #
      # +true+ on the base class: a confirmer exists to ask, so a subclass that
      # doesn't must say so, and one that forgets is credited with a gate it
      # does not have only if it also forgets to be {AutoApprove}. Override to
      # +false+ for any request-independent auto-answer.
      #
      # This is what makes +--no-confirm+ re-harden a wiring's verdict on its
      # own, with nothing in the detector special-casing the flag.
      #
      # @return [Boolean]
      def blocks_on_human? = true

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

        # @return [Boolean] +false+ — nobody is asked, so a tool gated by this
        #   confirmer holds autonomous egress however human-gated its wiring
        #   looks on paper
        def blocks_on_human? = false
      end

      # Shared stateless {AutoApprove} singleton, reusable across tools,
      # sub-agents, and hosts' yolo modes. (No +TERMINAL+ singleton: {Terminal}
      # is a demo chrome, and real front-ends bring their own.)
      AUTO_APPROVE = AutoApprove.new
    end
  end
end
