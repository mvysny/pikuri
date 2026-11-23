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

## Testbed findings: Thunderbird 160 (2026-11-23)

**How.** A headless `dev/testbed/session` (no Xvfb on the dev VM yet).
Each hand-off was a real command line, `Cu.createCommandLine([...], null,
Ci.nsICommandLine.STATE_REMOTE_EXPLICIT)`, given to Thunderbird's own
`MessengerContentHandler#handle`: the handler a remoted `thunderbird
-compose …`, `thunderbird mailto:…` or `thunderbird file.eml` reaches. The
compose window was read back over Marionette, and the outgoing MIME was
generated with `MimeMessage#createMessageFile` (`modules/MimeMessage.sys.mjs`)
into a temp file, so nothing was sent and no folder was written. **Not
yet covered:** the real `setsid thunderbird …` remoting into a `--display`
session, which needs `xvfb`. Code read from the snap's `omni.ja`:
`modules/MessengerContentHandler.sys.mjs`,
`chrome/messenger/content/messenger/messengercompose/MsgComposeCommands.js`.

Message used: `imap-message://alex%40novak.example@127.0.0.1/INBOX#3`,
"[riders] Sunday ride to Nuuksio" from Juha Salo. Such a URI is the Gloda
folder URI with `imap:` → `imap-message:`, plus `#<messageKey>` (it matched
`folder.getUriForMsg` on every INBOX message listed). Local Folders would
presumably be `mailbox:` → `mailbox-message:`; not tried.

| Hand-off | Result |
|---|---|
| `mailto:…?In-Reply-To=%3C<id>%3E&body=…` | **Threads.** Parsed into `compFields.references` (In-Reply-To goes last, after any `References=`); the MIME carries `References:` and `In-Reply-To:` (`MimeMessageUtils.getInReplyTo` takes References' last entry). Body kept, multiline. |
| `-compose "to=…,subject=…,body=First%20line%0ASecond%20line"` | **Multiline works.** Bare and `"…"` values are percent-decoded; only `'…'` is a raw literal, which is what architecture.md's `body='A%0AB'` test had hit (doc corrected). |
| `-compose "…,attachment=file:///home/…/Documents/scan-receipt.png"` | **Attached**, under the file's own name and size, read straight from `~/Documents`: snap Thunderbird reads non-hidden `$HOME`, so no staging. |
| `-compose "type=1,originalMsgURI='…#3',body=…"` | **Thunderbird's own reply**: To from the original, `Re:` subject, `References`, Thunderbird's quote. **`body=` dropped**, in HTML and with `format=text`; `message=<file>` dropped too. A Thunderbird-made reply can't carry the model's draft. |
| `-compose "type=3,originalMsgURI='…',to=…,body=FYI"` | **Forward as attachment works.** `to` and `body` kept; Thunderbird attaches the original itself as `message/rfc822` "`<subject>.eml`" (its copy in `~/Downloads/thunderbird.tmp/pid-N/`, removed on exit). The forwarded bytes never pass through the model. |
| `-compose "type=4,originalMsgURI='…',…"` | **Forward inline doesn't work**: an empty `Fwd:` with `References` and no original. Thunderbird starts an inline forward outside the compose window. |
| a staged `.eml` with `X-Unsent: 1` | **Opens as an editable draft** (`type` 9, plain text): To, Subject, `References` kept, From set to the identity, body verbatim. The MIME carries `References` + `In-Reply-To`. |
| `message=` / `.eml` under the agent's `/tmp` | **Blocks**: snap Thunderbird has a private `/tmp`, so the file is "not found" and a *modal* alert opens. Stage in {Pikuri::Thunderbird::Profile#outbox_dir}, as the `.ics` hand-off does. |

### What that means for the shapes

- **Reply with the model's text:** `mailto:` + `In-Reply-To` is the
  smallest change: one more allowlisted parameter in
  {Pikuri::Thunderbird::MailtoUri}, the Message-ID `thunderbird_mail_read`
  already takes. A quote, if wanted, is text pikuri copies from Gloda's body
  (the model writes none of it); ComposeGuard then checks the model's part
  only. The staged `.eml` does the same with full header control, which is
  more to get wrong for no gain here.
- **Reply without the model's text:** `-compose type=1` opens a
  Thunderbird reply for the user to write. The recipient comes from
  Thunderbird's reply logic, not from the model (though the original's
  `Reply-To` is the sender's to choose).
- **Forward:** `-compose type=3` (as attachment) with the model's note in
  `body`. Inline forwarding is out via `-compose`.
- **Attach a file:** `-compose attachment=`.
- So `-compose` becomes a second outbound transport beside `mailto:`. Its
  key set is wider than mailto's five (`from`, `preselectid`, `format`,
  `newsgroups`, `attachment`, `message`, `type`, `originalMsgURI`,
  `bodyislink`), so it needs a builder like `MailtoUri`: allowlisted keys,
  every value percent-encoded so a body can't carry a raw `,` or `'` that
  starts a new `attachment=` pair. Enforced by construction, as today.

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
  `:egress`" was written for case 1 and needs rewording either way. A
  forward makes it sharper: the human sees one `<subject>.eml` chip, not
  the tax-return PDF inside the forwarded mail.
- `Q_transport` — `-compose` for forward and attach only, or move compose
  onto it too, so there's one builder and one hand-off? `mailto:` is
  RFC 6068 and other mail clients read it; `-compose` is Thunderbird's own.
- `Q_reply_shape` — `mailto:` + `In-Reply-To` (the model drafts, threaded,
  no quote unless pikuri copies one in), `-compose type=1` (Thunderbird's
  reply, the user writes), or both? And does pikuri quote at all?
- `Q_guard_on_quotes` — mostly gone: Thunderbird's own forward and reply
  put the original in without the model, and a quote pikuri copies from
  Gloda is not model-authored, so ComposeGuard checks only the model's
  part. Left: is a pikuri-copied quote "renders literally"? It is text in
  the body, so yes, hidden characters included.
- `Q_forward_scope` — `forward_message_id` only, or also one attachment of
  a mail (`"2.1"`, the `thunderbird_mail_attachment_read` handle)? The
  latter needs the bytes staged from the mbox into the outbox dir, which
  pikuri would write.
- `Q_display_run` — re-run the table through the real `setsid thunderbird
  …` remoting in a `--display` session once `xvfb` is installed; the
  modal-alert cases matter most there, since a human sees them.
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
→ a `D_` entry in `design/decisions.md`; the § Testbed findings table →
architecture.md § Hand-off mechanics, for the shapes that ship; a
CHANGELOG line.
