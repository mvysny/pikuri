# "Act when you have enough; recommend, don't survey"

Status: **agreed, not built.** Pure prose, cheap, high value-per-token
— the single clearest remaining prose gap against `claude.txt`. No
harness work.

## The gap

Claude's behavioral core carries:

> When you have enough information to act, act. Do not re-derive facts
> already established [...] give a recommendation, not an exhaustive
> survey [...] Do not narrate options you will not pursue.

A sweep of every pikuri main prompt
(`grep -niE "enough information to act|recommendation|exhaustive|survey"`
over `*/prompts/*.txt`, excluding `persona-*.txt`) returns **nothing**.
The clause is absent from `pikuri-code/prompts/coding-system-prompt.txt`
and `pikuri-assistant/prompts/pikuri-assistant.txt` alike.

## Why it earns its place

It fights two opposite failure modes at once, and both are *worse* on a
smaller model than on Opus:

- **Premature wrap-up** — "I've done part of it, shall I continue?"
  when it has everything it needs to just finish.
- **Analysis paralysis** — surveying five options and narrating each
  instead of picking one and saying why.

It complements, rather than duplicates, what pikuri already has: the
anti-thrash error block (don't *loop*) and the closing rule (finish in
plain text). Those bound wasted *retries* and tell the model *how to
stop*; this tells it *when there's enough to move* and to *commit to a
recommendation*.

## Where it goes

Cross-cutting behavioral contract, not tool mechanics → the opening /
"Other guidelines" block of the main prompts, not a tool description
(Lesson 0 keeps only per-tool rules at the tools). Add to both
`coding-system-prompt.txt` and `pikuri-assistant.txt`.

Proposed wording (one line, tool-agnostic so it survives being wired
onto a differently-toolset agent):

> When you have enough to act, act — don't re-derive what's already
> established, and when you're weighing options give one recommendation
> with its reason rather than surveying all of them.

## Source

External study: `prompts-examples/system_prompts/claude-pikuri.md`
§12 ("Context-management awareness") and `claude-pikuri-prose.md`
Category 1 (the lone "brake on analysis-for-its-own-sake" in `claude.txt`).
