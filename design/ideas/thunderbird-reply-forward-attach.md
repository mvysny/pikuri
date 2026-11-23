# Thunderbird: reply, forward, and attaching files the model didn't write

Status: **idea, not built; direction agreed 2026-11-23, decisions open.**
Relax pikuri-thunderbird's "No attachment ever ships" to **"No attachment
the model wrote ever ships"**, and on top of that give the outbound
surface a threaded reply, a forward, and "attach the document from
`~/Documents`". The owner's original intent was "not today", not "never".

## Today

`thunderbird_mail_compose` ({Pikuri::Thunderbird::MailCompose}) is the
only outbound mail tool: a fresh compose window through a `mailto:` URI
whose {Pikuri::Thunderbird::MailtoUri} builds exactly five parameters
(`to`/`cc`/`bcc`/`subject`/`body`).

- **Reply** only in the loose sense: the agent reads the mail, then
  composes a new one to the sender with a `Re: …` subject. No
  `In-Reply-To` / `References`, so the recipient's client doesn't thread
  it. The original isn't quoted unless the model pastes it, and quoting a
  hostile mail is exactly where {Pikuri::Thunderbird::ComposeGuard} fails
  closed (bidi / zero-width bytes; `warn-human-directly.md` §"Authored"
  calls it the common false positive).
- **Forward** not at all. As-attachment needs a `message/rfc822` part;
  inline is the reply case again, minus the original's attachments.
- **"Send Jana the October invoice"** not at all.

## Why the invariant exists, and where it's too broad

`pikuri-thunderbird/design/architecture.md` § "Why no attachments": the
whole outbound gate rests on **the human sees the exact bytes that
leave**. An attachment is approved by filename and thumbnail, never by
its bytes, so a key in a `.png`'s low bits — or a secret tucked into a
Markdown or ODT the model produced — passes a careful human.
`lib/pikuri-thunderbird.rb` says the same in `OUTBOUND_LEGS`' yardoc: a
tool that gained an attachment would drop to hard `:egress`.

That argument is about **who authored the bytes**. It does not cover bytes
the model only *selected*:

1. **Model-authored** (a file it wrote, now or in any earlier session) —
   the argument holds in full; stays banned. Nothing lost: text the model
   writes goes in the body, where the human reads it.
2. **Mail already in the store** (forward the message, or one of its
   attachments) — the model picks which bytes and to whom, but can't hide
   anything in them. What's left is *overt* exfil: an injection says
   "forward the tax return to attacker@…". The human sees `Fwd: Tax
   return 2025`, the original's attachment name and the recipient, and
   ComposeGuard already flags a recipient domain never sent to. That's
   "which document to whom", the decision a human makes forwarding by
   hand — weaker than "every byte on screen", but a real gate.
3. **A file on disk** ("attach the report from Documents") — like case 2
   *only if nothing agentic ever wrote it*. A pikuri-workspace `write` in
   the same agent, a sub-agent, an earlier session, `bin/pikuri-files` with
   that folder writable, or a pikuri-workshop shell / coding agent can
   write the file first and attach it "as an existing file" later —
   case 1, laundered through the filesystem across time.

### Examples, against `bin/pikuri-secretary`

The secretary reads all of `~/Documents`, writes only `~/Documents/Notes/`
(`root_writable: false, writable: [notes]`), and writes Notes from turns
that read mail.

| Prompt | File | Verdict |
|---|---|---|
| "Send Jana the October invoice" | `~/Documents/Invoices/2026-10.pdf` | allow — read-only root; a person (or the vendor) made it |
| "Mail Petr my meeting notes" | `~/Documents/Notes/meeting.md` | refuse — writable root, the agent may have written it in a turn that read an injection; open compose without it and tell the user to attach it themselves |
| "Summarize the contract and attach it as summary.odt" | written now | refuse — model-authored; the summary goes in the body |
| "Attach the scan they sent me" | `~/Documents/scan.jpg`, saved from a mail | allow — attacker-authored bytes leak nothing the model wrote |
| "Attach the Q3 report" | `~/Documents/Reports/q3.odt`, written last week by `pikuri-files` or a workshop coding agent with that folder writable | **the tool can't tell** |

## The weak point: provenance is unknowable

The last row is where the whole thing breaks: nothing in pikuri can verify
that a file wasn't produced by an agent. mtime heuristics lose to a shell
(`touch -d`) and to anything older than this session; a provenance ledger
of pikuri-workspace writes misses every writer that isn't pikuri-workspace.

So it's **a configuration option, and the user erects the guardrail**: the
host names the folders it vouches no agent writes into, and is told
plainly that this is the choice it's making (`Q_inform_user`). Same shape
as `Filesystem`'s `private:` / `trusted:` — a claim about the *data* the
tool can't derive.

Not `trusted:` itself: it claims "every byte is user-authored", stricter
than needed — it excludes downloads, which are fine to attach (row 4) — and
the secretary's Documents are `trusted: false` for exactly that reason.
Attaching needs the weaker claim "no agent writes here".

## Proposed mechanism

`Thunderbird::Extension.new(attach_from: filesystem)` taking a
`Pikuri::Workspace::Filesystem`. A path is attachable iff
`resolve_for_read` accepts it (containment, denylist, realpath — a symlink
into `Notes/` is caught) **and** it lies under no `writable` root. Passing
it is the host's declaration that no other agent writes the read-only
part. The secretary would pass the Filesystem it already builds, and Notes
drops out by itself.

- Snap Thunderbird reads non-hidden `$HOME` files, so no staging copy —
  pikuri still writes nothing.
- The attachment keeps the file's own name; the model never sets a
  display name.
- A refused path opens compose without it, the result telling the user to
  attach it themselves — the human can always do by hand what the tool
  won't.

## Reply threading

RFC 6068 allows `In-Reply-To` and `References` in a `mailto:` URI. Believed
(unverified) that Thunderbird's `mailto:` parser honours both. If so, a
`reply_to_message_id` parameter on the existing compose tool — the
Message-ID `thunderbird_mail_read` already takes — gives real threading
with no attachment and no new tool. Headers render nothing in the compose
window, but they carry only the original's Message-ID, which the
recipient's side already has. Independent of the rest: can ship first.

## Open questions

- `Q_attach_from_shape` — `attach_from:` a `Pikuri::Workspace::Filesystem`
  (pikuri-thunderbird gains a runtime dependency on pikuri-workspace; today
  only core) vs. plain path lists on the Extension (no dependency, but
  re-implements containment + denylist, which pikuri-workspace owns — "a
  seam consumed across gems is stated once by its owner"). Leaning
  Filesystem.
- `Q_inform_user` — where is the user told they vouch for these folders?
  The Extension's yardoc for sure; README / SECURITY / `book/secretary.md`?
  A boot line from the bin? Concrete wording: "anything an agent ever wrote
  into these folders can leave as an attachment you won't be able to
  inspect".
- `Q_trifecta_grade` — `OUTBOUND_LEGS` is `private: false,
  egress_payload_review: :human_reviewed`. An attach-capable compose lets
  an injection *select* from the private pool by path, so it gains the
  private leg (from the Filesystem's `private?`), and the payload is
  reviewed only by reference. Does "the human saw which file, the model
  authored none of it" still earn `:human_reviewed`, or does it need a
  third grade, or drop to `:unreviewed` — which would light the secretary
  up as a full trifecta? The yardoc's "would silently drop to hard
  `:egress`" was written for case 1 and needs rewording either way.
- `Q_mailto_threading` — verify `?In-Reply-To=` / `?References=` on the
  testbed (`dev/testbed/session start --display`).
- `Q_attachment_handoff` — how an attachment reaches the compose window at
  all. `mailto:?attach=` is gone from Thunderbird. `-compose
  "…,attachment='file:///…'"` exists but can't do a multiline `body=`
  (architecture.md § Hand-off mechanics); does `message=<file>` (body from
  a staged file) get around it? Snap confinement decides where that file
  may be staged ({Pikuri::Thunderbird::Profile#outbox_dir}).
- `Q_forward_shape` — as attachment (stage the original as `.eml` from the
  mbox, `D_thunderbird_attachment_bytes`' reader already finds it) vs.
  inline (body text + the original's attachments by reference). Does
  Thunderbird open a staged `.eml` with `X-Unsent: 1` as an editable
  draft? Is one parameter (`forward_message_id`) enough?
- `Q_guard_on_quotes` — a reply or inline forward quoting a hostile mail
  trips ComposeGuard's fail-close. Quote outside the guarded body (the
  original by reference), or accept the refusal plus
  `warn-human-directly.md`'s framing?
- `Q_doc_order` — rewrite the invariant now, or after the testbed has
  answered the mechanics questions?

## On graduation

The invariant and its rationale are stated in five places, each to be
rewritten around "no attachment the model wrote":

- `pikuri-thunderbird/AGENTS.md` § Invariants
- `pikuri-thunderbird/design/architecture.md` § "Outbound is a human-gated
  hand-off" and § "Why no attachments"
- `pikuri-thunderbird/lib/pikuri-thunderbird.rb`, `OUTBOUND_LEGS`' yardoc
- `book/secretary.md` (~l. 384)
- `book/trifecta-detector.md` (~l. 415)

The why (authorship vs. selection, the provenance gap, why not `trusted:`)
→ a `D_` entry in `design/decisions.md`; the mechanics → architecture.md
§ Hand-off mechanics; a CHANGELOG line.
