# Multi-modal input — images first

Goal: let the **user** hand the model an image ("what's wrong in this screenshot?"), not just
let a tool do it. Images first; audio / PDF-as-pixels / video later, if ever.

## What already works (2026-11-04)

pikuri is already multi-modal on **one** path: a tool observation.

- `Workspace::Read` (`pikuri-workspace/lib/pikuri/workspace/read.rb`, `format_image`) sniffs
  PNG/JPEG/GIF/WebP via `Pikuri::FileType`, refuses > 5 MiB, reads the bytes once and answers
  `Tool::Result.new(content: note, attachments: [Pikuri::Attachment.new(mime:, filename:, bytes:)])`.
- `Pikuri::Attachment` (mime, filename, bytes) is the one attachment type pikuri carries;
  `#to_ruby_llm` is the only place a `RubyLLM::Attachment` is built (AGENTS.md "Attachments
  are bytes").
- `Tool#to_ruby_llm_tool` hands ruby_llm `[content, *attachments.map(&:to_ruby_llm)]` — the
  only shape ruby_llm treats as a multimodal tool result (`D_tool_always_returns_result`).
- `Agent::History` round-trips attachments on **any** message, user ones included: base64 inline
  in `to_h`, content-addressed files under `attachments/` in `#save` (`D_history_attachments`).
- `design/architecture.md` already says "vision/audio … are ruby_llm's" — no provider
  abstraction of our own.

So there is **no special image tool** and no special tool-call shape: an image is just an
attachment riding a tool result. What is missing is the *user* side.

## What ruby_llm 2.1 does

- **User message:** `chat.ask(text, with: "a.png")` / `ask_later` →
  `add_message(role: :user, content:, attachments: with)`. `with:` takes paths, URLs, IOs,
  `Attachment`s, or a Hash of groups (`Attachment.wrap`).
- **`Attachment.new(source, filename:, resolution:)`** — a **String source is read from disk or
  fetched over HTTP at construction** (MIME detection). Its own doc: "an unchecked String can
  access local files or internal network endpoints." `resolution:` (`:low`…`:original`) maps
  to the OpenAI `detail` field; llama.cpp presumably ignores it.
- **Wire, Chat Completions** (`protocols/chat_completions/media.rb`): an image becomes a
  `{type: 'image_url', image_url: {url: <data: URI or URL>}}` content part — exactly what
  llama-server's OpenAI endpoint accepts with an `--mmproj` loaded.
- **Tool-result images on Chat Completions** (`chat_completions/chat.rb:314-336`): tool
  messages are text-only on the wire, so ruby_llm splices a **synthetic user message**
  "Attachments from tool call <id>:" + the image parts right after the tool-result group. So
  `read`'s image already reaches the model as a `:user` message — consistent with our
  "nothing mid-conversation is `:system`" invariant, nothing to fix.
- Capability metadata: `model.supports?(:vision)` from `models.json` — useless for a local
  llama.cpp model (`assume_model_exists`).

## What's missing in pikuri

1. ~~`Agent#run_loop(user_message:)` — `String` only.~~ Done 2026-11-04: `attachments:`.
2. ~~`Event::UserTurn(content:, mid_loop:)` can't show an image.~~ Done: `attachments`.
3. `Extension#on_user_message(content)` — text only, **decided**: attachments are not passed,
   and an attachment-only turn skips the hook (its yardoc says so). See `Q_memory`.
4. `Control::Interloper#inject_user_message(content)` — text only.
5. ~~The bins: no syntax to attach anything.~~ Done in `pikuri-chat` only: `@path`. The
   other chat bins (`pikuri-code`, `pikuri-assistant`, …) still can't; lift
   `pikuri-core/bin/chat_attachments.rb` into `lib/` when a second one wants it.
6. ~~No vision-capability check.~~ Done 2026-11-04: `Agent#modalities` (see `Q_vision_probe`),
   verified live — `bge-m3` refused before sending with the history empty, Ornith-1.5 answered.

## Sketch

**Core** — **done 2026-11-04**: `run_loop(user_message: nil, attachments: [], transport: nil)`
and `Event::UserTurn#attachments`; contract in `Agent#run_loop`'s yardoc. An attachment-only
turn sends **no text part** (Anthropic refuses an empty one), and `History::Message#to_ruby_llm`
replays `""` + attachments as `nil` content to match. Pinned on the wire in
`history_round_trip_spec.rb`.

**`Pikuri::Attachment`** — **done 2026-11-04**: promoted from `History::Attachment`, with
`Tool::Result` and `read` moved onto it. Why one type and not a `History`-own copy:
`D_history_attachments`; the serialization warning is its yardoc plus the `members` pin in
`history_spec.rb`.

**Bins:** the smallest thing that works in a terminal — a token in the line, e.g.
`@~/shot.png what's wrong here?`, or a `/image <path>` line that stages an attachment for the
next turn. Terminals paste a dragged file as its path, so `@path` gets drag-and-drop for free.
Clipboard images (`wl-paste --type image/png`) are a later nicety.

**Construction safety:** the bin reads the file once
(`Pikuri::Attachment.new(mime:, filename:, bytes: File.binread(path))`); the type admits no
path or URL, so nothing ever triggers ruby_llm's URL fetch (Privacy first), and the transcript
holds the image as it was at send time, not whatever sits at that path later.

## Open questions

- ~~`Q_api_shape`~~ **Decided 2026-11-04:** an `attachments:` kwarg on `run_loop`, no
  `UserMessage` value; `Event::UserTurn` carries the `Pikuri::Attachment`s themselves (see
  Sketch). Not an id resolved against `History`: `History` is a snapshot built by
  `export_history`, not a live store, so resolving an id means an agent handle (the History
  seam forbids reading the chat) plus a full export per event. Carrying the value costs
  nothing (a reference to bytes the chat already holds), and `#save` already dedups on disk by
  content hash. Every other event is a self-contained value too.
- ~~`Q_vision_probe`~~ **Decided 2026-11-04: probe ourselves.** The deciding fact is not the
  retries but **history poisoning**: `run_loop` appends the user message before `complete`
  and nothing removes it when `complete` raises, so on a blind model every *later* turn
  resends the image and 500s again until `/clear`. A blind model that `read`s a PNG poisons
  the history the same way, via the tool result. Turning off ruby_llm's retries fixes
  neither (and retrying a 500 is right for a transient server fault). Shape:
  - `ContextWindowDetector` reads `modalities` from the `/props` response it already fetches
    (router hop included), so the probe adds no request. Each modality is tri-state:
    `true` / `false` / `nil` = unknown (hosted provider, non-llama server); only a measured
    `false` refuses, so an unknown server falls through to the provider's own error
    (`D_probe_when_unknown`).
  - Carry the modalities, not a vision flag, and match by MIME (`image/*` → `vision`,
    `audio/*` → `audio`), so the core never says "image" (`Q_beyond_images`).
  - `run_loop` refuses **before** `add_message`, naming the attachment and the model — the
    probe moves ahead of the append — so the history stays clean.
  - `Tool#to_ruby_llm_tool` drops an attachment the model can't take and appends a text note
    to the result instead; covers every attachment-returning tool, and `read` stays ignorant
    of the model.

  **Measured 2026-11-04** against the
  `~/.pikuri-examples-config.yaml` server (llama.cpp `b10438-Debian`, **router mode**, model
  `Ornith-1.5` = `ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M`):
  - Bare `GET /props` on the router: `role: "router"`, **no `modalities` key**.
  - `GET /props?model=Ornith-1.5` (the hop the detector already makes for `n_ctx`):
    `modalities: {"vision"=>true, "video"=>true, "audio"=>false}`, beside `media_marker` and
    `chat_template_caps`. So the field name is `modalities.vision`. That hop **autoloads the
    model** (`models_autoload: true`; the first call outlived a 10 s timeout), the same cost the
    `n_ctx` probe already pays.
  - `GET /v1/models` on the router answers **without loading anything**: each entry carries
    `architecture: {input_modalities: ["text","image"], output_modalities: ["text"]}` (the
    embedders/reranker report `["text"]`). This is a router extension; a single-model
    llama-server probably doesn't have it (unverified).
  - The preset has no `--mmproj`; `--hf-repo` pulled the projector automatically, so with a
    `-hf` model "vision-capable" is the default, not an opt-in.
  - End to end: a 64×64 red|blue PNG as an `image_url` data-URI part on `/v1/chat/completions`
    → "red occupying the left half and blue filling the right half." Works today with exactly
    the part shape ruby_llm emits.
  - **Text-only model**, measured with a `Qwen3.8-Dense-text` preset (`no-mmproj = true`;
    `no-mmproj = 1`, `mmproj-auto = false` and `LLAMA_ARG_MMPROJ_AUTO = false` all become
    `--no-mmproj-auto`):
    - `/v1/models` says `input_modalities: ["text"]` while the model is still **unloaded**.
      The router knows the answer without loading anything.
    - `/props?model=Qwen3.8-Dense-text` → `modalities: {vision: false, video: false,
      audio: false}`.
    - The image request → **HTTP 500**, `{"error":{"code":500,"message":"image input is not
      supported - hint: if this is unexpected, you may need to provide the mmproj",
      "type":"server_error"}}`.
  - **ruby_llm retries that 500.** `RubyLLM::ServerError` is in `Transport::Connection`'s
    `retry_exceptions` and `max_retries` defaults to 3, and pikuri overrides neither. So a
    blind model gets the same image request 4 times with backoff, and the turn then dies with
    `RubyLLM::ServerError`. The message is helpful but generic, and nothing tells the user
    *which* message carried the image. This is the strongest argument for the probe:
    refuse an image turn before sending it, with a pikuri message.
- `Q_image_budget` — an image costs tokens. **Measured** (Ornith-1.5, solid-colour square
  PNGs, `prompt_tokens` minus ~26 for the text): 64 px ≈ 9, 256 px ≈ 64, 1024 px ≈ 1024,
  2048 px ≈ 4096, **4096 px ≈ 4096**: one token per 32×32 px, **capped at ~4096 by llama.cpp's
  mtmd**. So downscaling isn't needed for correctness, and no image library is needed. A
  full-resolution screenshot costs ~4 K of a 64 K window (6 %), so it matters only when images
  pile up. Does `context-budget.md` need to know an image's cost? (The cap is per
  model/projector; another family, e.g. Gemma 3's flat ~256, will differ.)
- `Q_trifecta` — a user-attached image is user input, not a tool observation, so no tool leg
  applies. But a screenshot of a web page or e-mail carries *someone else's* text. Treat it
  like typed/pasted text (the user vouches for it) — most likely — or does it deserve a note
  in `SECURITY.md`?
- `Q_mid_loop` — should `Interloper#inject_user_message` carry attachments too (pikuri-tui:
  drop an image while the agent works)? Probably not in the first cut.
- `Q_subagents` — the `agent` tool's task is a String; a sub-agent never sees the parent's
  image. Fine (the parent can tell it a path and the child can `read` it), as long as the
  child persona has `read`.
- `Q_memory` — `on_user_message` gets text only; should pikuri-memory at least record
  "[user attached image.png]" so a recalled fact isn't missing its referent?
- `Q_listener_render` — `Listener::Terminal` stays silent on `UserTurn` (it never echoes
  typed input), so it only matters to a host that renders its transcript from events —
  pikuri-tui: a dim `📎 shot.png (123 KB, image/png)` line, mirroring
  `Tool.describe_attachments`?
- `Q_beyond_images` — ruby_llm's Chat Completions path also does audio (`input_audio`) and
  PDFs (`file` parts); llama.cpp does audio with an audio mmproj. Same plumbing, so the core
  API should not say "image" anywhere — only the bins and the probe would.

## First cut

**Done 2026-11-04**: `Pikuri::Attachment` (with `Tool::Result` and `read` on it, the
`members` pin), `attachments:` on `run_loop` + `UserTurn`, the wire-level `History` round
trip, and `@path` in `pikuri-chat` (`book/chat.md`; verified end to end against Ornith-1.5).
The probe followed the same day (`Q_vision_probe`). Downscaling and mid-loop injection wait
until a real model shows they're needed.
