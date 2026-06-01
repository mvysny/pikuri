# The pikuri guide

A short, sequential book on pikuri. Each chapter builds on the
vocabulary the previous one established, so reading order matters
— don't jump into chapter 5 without chapters 1 and 2 first.

If you want the reference instead of the narrative, every public
class and module is documented with YARD headers in the sources.
Run `bundle exec yard` inside any gem directory for a browsable
local site, or — once gems are published — see
<https://rubydoc.info/gems/pikuri-core> and its siblings.

## How the guide is shaped

Twelve chapters in three movements. The first two are the base
vocabulary; the middle six are the **assistant track** (broader
audience, privacy-conscious user), capped by the security
chapter that earns the reassurance prefixes above each earlier
chapter; the last four are the **code track** (narrower
audience, developer-flavoured), revisiting MCP and security at
the sharper edges. Tasks and skills close out as smaller
chapters that apply across both tracks.

## Chapters

1. **[Your first conversation](01-chat.md).** Install
   `llama.cpp`, start the server, run `pikuri-chat`. Establishes
   the base vocabulary: `Pikuri::Agent`, `Pikuri::Tool`,
   listeners, the Thought → Tool-call → Observation loop. The
   four bundled tools and the privacy posture of each search
   provider.
2. **[Sub-agents](02-subagents.md).** One new concept on top of
   chapter 1: delegation. The `Persona` record, the
   `SubAgent::Extension`, the configure/bind dance. Demo via
   `pikuri-minions` — fan out three research questions in
   parallel, get one synthesised answer back. This is also
   where pikuri's main privilege-separation story starts.
3. **[Agentic search and the vector DB](03-vectordb.md).** One
   new feature on top of chapter 2: semantic recall over a local
   corpus. The chunker / tokenizer / embedder / backend /
   reranker pipeline, in-memory vs Chroma backends, and why the
   demo agent has no internet access — treat the corpus as
   private, give the reader an agent that can't leak it. Demo via
   `pikuri-corpus` against the pikuri guide itself. (The
   privilege-separated `LIBRARIAN` persona, for an agent that
   *does* have egress, is deferred to chapters 6–7.)
4. **[Memories](04-memories.md).** Durable facts the agent keeps
   across conversations, paired with chapter 3's vector DB for
   recall. The three retrieval tiers (resident persona / automatic
   prefetch / `recall` tool), the mem0 + Qdrant sidecar, why the
   extraction model must be non-reasoning, and why automatic
   capture is only safe on a no-egress agent. Demo via
   `pikuri-memory`. This is where the privacy posture starts to
   *matter*.
5. **[Your first MCP server](05-mcp.md).** The gentle MCP intro:
   one low-stakes server (a public book-catalogue reader, no
   credentials, nothing private wired in), your first taste of
   Docker as the boundary, the registry/servers split, the
   verifier and synthesizer that are `pikuri-mcp`'s distinctive
   contributions. The sharper MCP shapes — credentials,
   untrusted code, the full container threat model — wait for
   chapter 10.
6. **[Security: picking a defense for your harness](06-security.md).**
   The synthesis chapter. Why there's no NX flag for tokens,
   the lethal trifecta, the defense kit, a decision procedure
   for your own harness, the five worked attacks, and how
   pikuri's structural bet compares to Claude Code's
   operational one. No new binary — read it before pointing any
   write- or network-capable agent at something sensitive. This
   is where every "chapter 6 explains why" reassurance pays off.
7. **[pikuri-assistant (stub)](07-assistant.md).** Placeholder.
   The privacy-conscious assistant binary that integrates
   vectordb, memories, MCP, and the four bundled tools. Stub
   until the gems it depends on stabilise.
8. **[The in-repo coding agent](08-code.md).** The dense
   chapter. Three new seams at once (`Workspace`, `Confirmer`,
   `Sandbox`), file + shell tools, and read-only code recon via
   the `FILE_MINER` persona. The mechanics; the threat model
   moves to chapter 9 as its closing pair.
9. **[Security revisited: the coding-agent shape](09-security-revisited.md).**
   What `pikuri-code`'s defaults actually protect and where they
   stop, plus wrapping the whole pikuri process in Docker for
   when the in-process defenses aren't enough.
10. **[MCPs revisited: containerised servers](10-mcp-revisited.md).**
    The harder MCP shapes: the official GitHub MCP in Docker as
    the worked example, plus npx- and pip-based community MCPs,
    Playwright with its open-web surface, and the full threat
    model for `pikuri-mcp`.
11. **[Task tracking](11-tasks.md).** A short chapter near the
    end. What `pikuri-tasks` is, why an agent benefits from
    externalized working memory, and the three design choices
    that shape its four tools — status-in-verb-name,
    content-as-identifier, newline-separated mass-create.
12. **[Agent Skills (stub)](12-skills.md).** Placeholder
    chapter — what skills are in one paragraph, a minimal `lol`
    demo, and a TBD list. Coming back to flesh out once the
    guide has workflows that motivate it.

Further chapters (a deeper `pikuri-assistant` walkthrough, more
advanced coding-agent recipes) will land as those surfaces
stabilise.
