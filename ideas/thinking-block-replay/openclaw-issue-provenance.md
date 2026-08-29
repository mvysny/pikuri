# Why the "signatures are endpoint-specific" claim was demoted

An earlier draft of the idea file called per-transport identity
"probably the most interesting fork in this note" and proposed recording
`api_base` per message — a `History` schema change with a migration
story. Checked 2026-08-29; the evidence does not carry that weight.
Kept here because the claim is plausible and someone will re-derive it.

## What was cited

[openclaw#92019](https://github.com/openclaw/openclaw/issues/92019) —
real, closed 2026-06-10, titled *"anthropic-messages replay: preserved
thinking-block signatures hard-fail (400 Invalid signature) on proxied
endpoints / model-switch"*. Body:

> But Anthropic thinking-block signatures are **model-specific and
> endpoint-specific**. Two real-world conditions break it:
>
> 1. **Proxied endpoint** — when the Anthropic provider's `baseUrl` is not
>    `api.anthropic.com` (proxy/gateway), the preserved signature is not
>    guaranteed valid on replay.
> 2. **Model switching within a session** […] Anthropic rejects the
>    cross-model signature.

## Why it does not support the fork

1. **It is a reporter's root-cause hypothesis in a bug body**, not a
   vendor statement. The issue is real and the symptom was real; the
   explanation is the reporter's.
2. **The endpoint half is about rewriting proxies** — the body names
   Bifrost and LiteLLM. A gateway that rebuilds request bodies is a
   different failure from a first-party alternate endpoint, which is what
   the docs actually address: "`signature` values are compatible across
   platforms (the Claude API, Amazon Bedrock, and Google Cloud). Values
   generated on one platform work on another."
3. **The model-switch half is contradicted** by the current docs, which
   say a foreign block is silently ignored rather than rejected. Either
   the behaviour changed since June 2026 or the reporter's diagnosis
   conflated two causes.

## The other citation was weaker still

[claude-code#10627](https://github.com/anthropics/claude-code/issues/10627)
— real, closed 2025-10-30, `[Bug] Anthropic API Error: Invalid signature
in thinking block`. A bare 400 report that never mentions a model switch.
It was cited for "the most-reported form of this bug in the wild"; it
does not support that.

## What killed the fork outright

The live probe (see `provider-survey.md`): model ids echo verbatim on
llama.cpp, so the existing `model_id` comparison is sound on the backend
that matters. And under the chosen option the whole block is dropped on
mismatch, so a weak identity test can only fail *same-model* — losing the
model's own reasoning, never injecting a foreign one. Safe direction, no
schema change.

Worth reopening only if a rewriting proxy enters the picture, or if the
probe returns `equal? false` on a backend someone actually uses.
