# Emphatic skill-invocation language

Status: **agreed, not built — low priority, try-and-measure.** Pure
prose tuning of the skills system-prompt snippet. No harness work.

## The gap

`Catalog#format_for_prompt`
(`pikuri-skills/lib/pikuri/skill/catalog.rb:70`) introduces the
`<available_skills>` block with a mild nudge:

> The following skills provide specialized instructions for specific
> tasks. Use the `skill` tool with the skill's name to load its full
> instructions.

Claude's equivalent is forceful:

> When a skill matches the user's request, this is a BLOCKING
> REQUIREMENT: invoke the relevant Skill tool BEFORE generating any
> other response.

The *anti-hallucination* half is already covered — `SkillTool`'s
description (`skill_tool.rb:41`) says "do NOT retry with a guessed
name." What's missing is the *use-it-instead-of-winging-it* override.

## Why it might earn its place

A skill only adds value if it actually fires *instead of* the model
answering from its own weights. A model's default is to answer from
training; the forceful "BLOCKING REQUIREMENT" phrasing exists to
override that default. A smaller local model defaults to its own
knowledge *more* readily than Opus, so if anything the override is
needed more here — this is one of the few places the comparison argues
pikuri should match Claude's *volume*, not just its content.

## Why it's low-priority / measure first

Forceful language cuts both ways: over-eager skill loading on tasks a
skill doesn't actually match is pure ceremony and latency. Claude pairs
the BLOCKING phrasing with a hard *match* condition ("when a skill
matches the user's request"). Keep that conditional — the emphasis is
on "if it matches, you must," not "always load a skill." Worth A/B-ing
on the target model before committing: does the stronger wording raise
correct fires more than it raises spurious ones?

## Where it goes

The `<available_skills>` snippet itself (`catalog.rb:format_for_prompt`),
not a per-binary `*.txt` main prompt. That snippet is the skill
subsystem describing its own mechanism — it already names the `skill`
tool — so it sits with the persona/tool-surface carve-out to the
"no tool names in a main prompt" rule, alongside `<available_agents>`
and `<available_mcps>`.

Proposed addition (keep the match-conditional):

> When a skill matches the task, load it with the `skill` tool *before*
> answering from your own knowledge — the skill's instructions take
> precedence. If none matches, just proceed normally.

## Source

External study: `prompts-examples/system_prompts/claude-pikuri.md`
§9 ("Skills / extensibility") — "steal Claude's emphatic phrasing,
because the use-the-tool-don't-wing-it override genuinely needs the
volume, especially on a smaller model."
