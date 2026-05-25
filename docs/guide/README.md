# The pikuri guide

A short, sequential book on pikuri. Each chapter builds on the
vocabulary the previous one established, so reading order matters
— don't jump into chapter 03 without chapters 01 and 02 first.

If you want the reference instead of the narrative, every public
class and module is documented with YARD headers in the sources.
Run `bundle exec yard` inside any gem directory for a browsable
local site, or — once gems are published — see
<https://rubydoc.info/gems/pikuri-core> and its siblings.

## Chapters

1. **[Your first conversation](01-chat.md).** Install `llama.cpp`,
   start the server, run `pikuri-chat`. Establishes the base
   vocabulary: `Pikuri::Agent`, `Pikuri::Tool`, listeners, the
   Thought → Tool-call → Observation loop. The four bundled tools
   and the privacy posture of each search provider.
2. **[Sub-agents](02-subagents.md).** One new concept on top of
   chapter 01: delegation. The `Persona` record, the
   `SubAgent::Extension`, the configure/bind dance. Demo via
   `pikuri-minions` — fan out three research questions in
   parallel, get one synthesised answer back. This is where you
   first see pikuri's Extension protocol in action.
3. **[The in-repo coding agent](03-code.md).** The dense chapter.
   Three new seams at once (`Workspace`, `Confirmer`, `Sandbox`),
   file + shell tools, and read-only code recon via the `SCOUT`
   persona. Includes the threat-model discussion you should read
   before pointing `pikuri-code` at anything sensitive.
4. **[MCP and `pikuri-assistant`](04-mcp.md).** Plugging in tool
   servers somebody else wrote — the official GitHub MCP server
   in Docker as the worked example. Where `pikuri-mcp`'s
   distinctive contributions live: the pre-flight
   prompt-injection verifier and the description synthesizer.
   Closes with its own threat-model section.
5. **[Agent Skills (stub)](05-skills.md).** A placeholder
   chapter — what skills are in one paragraph, a minimal `lol`
   demo, and a TBD list. Currently shaped to be skippable;
   coming back to flesh out once the guide has workflows that
   motivate it.

Further chapters (a deeper `pikuri-assistant` walkthrough, more
advanced coding-agent recipes) will land as those surfaces
stabilise.
