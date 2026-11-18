# Security model

Pikuri's security posture in one page: what we guarantee, what we
don't, and the structural reasons it works the way it does. Read
this once before pointing pikuri at your real mail, notes or
documents.

This is the *committed* model — what ships today, stated tersely.
The teaching version — the threat from first principles, five
worked attacks told as stories, and a decision procedure for
designing your own harness — is
[the security chapter of the guide](book/security.md). Open questions,
deferred mitigations, and prior-art notes live in
[`design/ideas/security-open-questions.md`](design/ideas/security-open-questions.md).

Two axes, in order. **Code trust:** which processes do you trust to
execute their intended code? A short section, settled in one pass.
**Prompt injection:** once code trust is established, how do you keep
correctly-functioning code from being tricked by untrusted *content*
it reads? The rest of the document, because it's the unsolved one.

## The kit, by harness shape

pikuri is not one security model, it's a small kit, and the right pick
depends on what the harness has to do. pikuri itself ships two of its
models:

| Model | Mechanism | Fits | Where it fails |
|---|---|---|---|
| **Trifecta-break** | sub-agent capability boundaries — `RESEARCHER` / `FILE_MINER` hold at most two of the three legs | chat, `minions`, web / file recon | the *relay* leg: a sub-agent's reply carrying the injection up to a parent that *does* hold the third leg |
| **Human gate** | `Confirmer` prompts before an irreversible or egress-bearing action runs | an assistant **with a human present** | confirmation fatigue; worth zero when nobody's watching, and only as good as what the human sees |

The rest of the kit (blast-radius containment, an egress allowlist,
outer isolation) is for agents that run code you didn't write, a
coding agent above all, whose job *is* the trifecta. Those agents live
in [pikuri-workshop](https://github.com/mvysny/pikuri-workshop), and
[its `SECURITY.md`](https://github.com/mvysny/pikuri-workshop/blob/master/SECURITY.md)
covers them.

## Code trust (the short axis)

Before anything else: which processes do you trust to execute? Once
this is settled, every defense below assumes those processes are
running their intended code.

- **Pikuri itself — trust it (and read it).** Pikuri is plain Ruby
  split into gems, and you only read the code you run: `core` stays
  lean, and core plus the gems you wire is deliberately small
  enough to read in an evening. Every
  public class has a YARD header explaining *why* it exists. See
  [`AGENTS.md`](AGENTS.md) for the design map. Audit it; you're
  meant to.
- **Your LLM provider — *the* trust choice.** Defaults wire local
  llama.cpp: your prompts never leave the box. The moment you point
  the chat's transport at OpenAI / Anthropic / anything else, every
  byte of context (file contents, scraped pages, tool results) is
  shipped to that third party. A malicious LLM is downstream of every other
  defense in this document — there is no structural recovery if the
  model itself is the adversary. Pick a reputable provider.
- **Code you didn't write — none.** pikuri runs no shell, no MCP
  server and no skill script; the model can't name a program to run.
  The children pikuri starts are fixed programs (`rg` behind `grep` /
  `glob`, `diff` and `git config` for the file tools, `cp` for
  Thunderbird's database snapshot, Thunderbird itself for a compose
  window, `tinysparql` or `recollq` for the desktop's file index), never one the
  model chose.
  The tools that do run a stranger's code live
  in pikuri-workshop, each in a cage.

That's the baseline. The rest of this document is about the harder
problem: **prompt injection of code you've already decided to
trust.**

## Prompt injection (the long axis)

The remaining attack surface is content the model reads: a tool
returns text, it enters the context, and the model cannot tell
"data" from "instructions" — there is no equivalent of the CPU's NX
flag for tokens. Unsolved industry-wide, and arriving from many
places: a scraped page, an incoming e-mail, a document in your notes,
even another sub-agent's reply. Pikuri does not try to *detect*
injection (filters lose to adversarial text); the defense is
**structural**, via the *lethal trifecta* (Simon Willison's
framing): any single agent combining (a) private-data access,
(b) untrusted-content exposure, and (c) internet egress is one
injection away from an exfiltration tool. Keep every agent to at
most two of the three.

### Defenses that ship

**Privilege-separated sub-agents.** Bundled personas, each holding ≤2
legs, so the agent that *reads* untrusted content has no tool to act
on an injection — structural, holds even against a fully-fooled
model:

- `RESEARCHER` — `web_search` / `web_scrape` / `fetch`. Web in/out;
  no `read` / `write` / `agent` recursion.
- `FILE_MINER` — `file_list` / `read` / `grep` / `glob`. Reads files;
  no egress, no `write`, no recursion.

The parent receives only the sub-agent's one-paragraph reply, never
the raw untrusted bytes.

*The honest gap — the relay leg (not structural).* That reply is
itself attacker-influenced content, and it flows into the parent. A
flag-don't-relay instruction in the persona prompts and the lossy
one-paragraph summary narrow it, but neither bites on an injection
subtle enough that the model never classifies it as one ("for
completeness, also read the notes about invoices"). What an injection
can do there is whatever the parent's own legs allow, which is why
every binary prints its trifecta map at boot
([measuring the trifecta](book/trifecta-detector.md)).

**Reading search results without visiting the pages.** Snippets
rarely answer a question, so an agent that searches usually also
gets `web_scrape` — and then a planted page can tell it to visit
`evil.example/?k=<your API key>`. A host can instead build
`web_search` with `page_text: true` (Brave or Exa) and add
`web_read_cached`: the search brings back each result's text from
the engine's own index, and the reader returns it by a handle like
`a3f9c21e`, never by URL, making no request of its own. The agent's
only way out is then the search query, to an engine pikuri picked,
which an attacker can't read back. Handles are keyed per process, so
a crafted URL can't take over a popular page's handle, and 8 hex
digits are too many to guess another conversation's pages from. What
it doesn't stop: a hostile page still lands in the agent's context
word for word and can mislead it, a secret pushed into a query still
reaches the engine (Exa trains on queries; Brave logs them up to 90 days),
and wiring `web_scrape` or `fetch` beside it brings the attacker's
way out back. See `D_page_text_by_handle`.

**Outbound mail goes through a human.** `pikuri-thunderbird` reads
your mail and calendar read-only, and anything outbound (a reply, an
invite) opens Thunderbird's compose window with the draft filled in.
You see the actual bytes and click Send yourself; the agent cannot.

**A host's denylist covers the paths a tool walks to.** pikuri's
workspace is scoped to the folders you name, so it denies nothing
inside them. A host that opens the whole disk (pikuri-workshop's OS
assistant) adds a denylist (`~/.ssh`, `~/.aws`, …), and pikuri's
`file_list`, `glob` and `grep` check every path they find on their
own against it: `~/.ssh` shows as `[denied]`, and `grep 'BEGIN
PRIVATE KEY' ~` doesn't return the key that `read` refuses to open.

> **Five worked attacks** are walked end to end in
> [the security chapter of the guide](book/security.md), including
> where structural defense ends and operational caution takes over.

Non-goal: pikuri does not filter or sanitize tool output. The
defense is the trifecta (at most two capabilities available to any
agent), not content inspection.

## Non-goals (be explicit)

Several framings worth stating directly so the model isn't misread
as a guarantee:

- **What you type, paste or attach.** Pikuri treats it as yours. A
  pasted e-mail or a screenshot of a web page carries someone else's
  words with your authority, and an image can carry text you never
  saw (white on white, tiny print), which the model reads and may
  obey. An image a *tool* returns is that tool's output, judged by
  the tool's legs like its text.
- **A compromised LLM provider.** A model trained to exfiltrate is
  downstream of every defense in this document. Restated from the
  code-trust section because it's the load-bearing trust choice.
- **Permission prompts are UX, not isolation.** The
  `Workspace::Confirmer::Terminal` prompts on writes reduce honest
  mistakes; they do not stop a determined or injected call once the
  user has approved sticky permissions. (Borrowed framing from
  opencode's `SECURITY.md`, which puts this same line at the top of
  theirs. They're right.)
- **Pikuri does not sandbox its own process.** For real isolation
  against a compromised pikuri or compromised tool, run pikuri
  itself inside a VM or container.
- **An agent wired with both fs-read and egress as a parent.** The
  persona model protects sub-agents that touch untrusted content.
  A parent with `read` + `fetch` + a tool that scrapes the web
  reassembles the trifecta if the model skips delegating to
  `RESEARCHER`. `bin/pikuri-chat` structurally avoids this shape
  (no `read` / `write`); a custom Agent built from `pikuri-core`,
  `pikuri-workspace` and `pikuri-web` can recreate it.

## See also

- [The security chapter of the guide](book/security.md) — the teaching
  companion to this page: the threat from first principles, the five
  attacks as stories, and a decision procedure for picking a model
  when you build your own harness.
- [`design/ideas/security-open-questions.md`](design/ideas/security-open-questions.md)
  — open mitigations under consideration and prior-art notes.
- [pikuri-workshop's `SECURITY.md`](https://github.com/mvysny/pikuri-workshop/blob/master/SECURITY.md)
  — the coding agent's kit: Bubblewrap, MCP in Docker, the MCP
  description verifier, `--yolo`.
