# Typed transport classes (private vs public)

Status: **designed, not built.** The model is settled (this file); the
sequencing note at the bottom is the live part. Staging area — drain
into source + `book/` as it lands.

Related, already in the repo:

- [`SECURITY.md`](../SECURITY.md) §"Code trust" (LLM-provider bullet) —
  the shipped-today version: a boot banner naming the outbound
  provider. This note is the structural replacement for that banner.
- [`private-context-taint.md`](private-context-taint.md) — the runtime
  egress-leg story. Typed transports are about *which provider* bytes
  go to (private vs public endpoint); taint is about *whether* a given
  context is allowed to egress at all. Adjacent, not the same axis.
- `book/trifecta-detector.md` — the shipped detector, the third privacy
  story and the one closest to being confused with this. **Whoever writes
  the transport-classes material owns that contrast**, and it is one
  sentence: the detector asks "does this *agent* hold all three legs?",
  transport classes ask "is the *LLM endpoint* private?". A wiring can pass
  either and fail the other — a local-model agent with `fetch` holds egress;
  a leg-free agent still ships every prompt to OpenAI. Two privacy stories
  the book must not let a reader merge.

**Staleness note (recorded 2026-05, while shipping `pikuri-vectordb`):**
the sketch below assumed a `Pikuri::Transport::Reranker::*` location.
The reranker actually shipped under `Pikuri::VectorDb::Reranker`
(`Reranker::LlamaServer` over `/v1/rerank`), *not* a `Transport::`
type. So the "rerankers don't exist in ruby_llm" argument still holds,
but the concrete class path in the sketch is now wrong — a future
implementation would classify the existing `VectorDb::Reranker`
instance, or hoist it, rather than introduce the path shown here.

---

## The weak version we ship today

A loud startup banner at the privacy boundary, documented in
[`SECURITY.md`](../SECURITY.md) §"Code trust" — LLM provider bullet
("Outbound LLM provider: api.openai.com — your prompts and tool
results will be sent there"). Fine sketch, structurally weak — the
user can click through a banner, and per-action banners ("indexer
about to send 3 MB to api.openai.com") are inconsistent with the chat
path that has been silently sending prompts to the same provider all
along. The leak is set at chat-config time, not at fire time.

## Stronger shape

Surfaced while scoping pikuri-vectordb (which adds two more LLM-shaped
transports — embedder and reranker — on top of ruby_llm's chat
transport): classify the transport instance itself as `:private` or
`:public`, derived from its endpoint host, and let
`Pikuri::Agent.new` refuse to mix classes by default.

Rough shape:

    module Pikuri::Transport
      class Local
        def privacy_class; :private; end
      end
      class OpenAI
        def initialize(api_key:, base_url: 'https://api.openai.com')
          @base_url = base_url
        end
        def privacy_class
          URI(@base_url).host =~ /\A(localhost|127\.|\[?::1)/ \
            ? :private : :public
        end
      end
      # Embedder::*, Reranker::*, etc. each declare their own.
    end

    Pikuri::Agent.new(transport: chat, privacy: :strict)
    # extensions / sub-agents whose transports differ in class are
    # rejected at construction. :mixed opts out and logs every
    # transport class loudly at boot.

Three load-bearing points:

- **Classification belongs to the transport instance**, derived
  from the URL host. Loopback / `::1` / Unix socket → `:private`;
  everything else → `:public`. LAN IPs, Tailscale endpoints, a
  Caddy reverse-proxy on `localhost:8080` pointed at OpenAI —
  pikuri can't verify network topology and won't try. Documented
  limitation, not a defect.
- **Fail-fast at construction, not per-request.** Strict mode
  refuses cross-class wiring; `:mixed` is the explicit opt-in for
  "private chat + public embedder" with loud boot logging.
  Default is `:strict` in `bin/pikuri-assistant`; no-op in
  `bin/pikuri-chat` where there's only the one transport today.
- **The concept ends up broader than ruby_llm.** Embedders ride
  `RubyLLM.embed`; rerankers don't exist in ruby_llm at all, so
  `Pikuri::Transport::Reranker::*` is pikuri-core's own
  first-class type, not a ruby_llm adapter. Argument for putting
  classification *above* ruby_llm in the abstraction stack
  rather than bolting it onto ruby_llm's config. (See the
  staleness note above — the reranker shipped under `VectorDb::`,
  so this would classify that existing instance.)

`:private` and `:public` are also docs anchors — named concepts
in the guide so the cliff is teachable, not something the user
discovers from a banner one day.

## Sequencing

pikuri-vectordb v1 ships with plain URL arguments (`embedder:` /
`reranker:` accept strings or transport objects interchangeably), and
typed transports land in a follow-up session that touches pikuri-core
and pikuri-vectordb together. Vectordb's transport configuration is
constructor-only, so retrofitting is local.
