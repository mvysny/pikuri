# Thunderbird: reply and forward

Status: **idea, not built; direction agreed 2026-11-23, narrowed
2026-11-24 (no file attach), decisions open.** Give pikuri-thunderbird's
outbound surface a threaded reply and a forward. Its "No attachment ever
ships" narrows to **"the only attachment that ships is a stored mail
Thunderbird forwards itself"**; a file from disk stays out, and the user
attaches it by hand (§ Rejected). The owner's original intent was "not
today", not "never".

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
- **"Send Jana the October invoice"** not at all, and it stays so: the
  model composes, the user attaches.

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
2. **Mail already in the store** (forward the message) — the model picks
   which mail and to whom, but wrote none of its bytes. What's left is
   *overt* exfil: an injection says "forward the tax return to
   attacker@…". The human sees `Fwd: Tax return 2025`, the recipient
   (ComposeGuard flags a domain never sent to), and — one double-click
   away — the mail itself. A careful human catches it: § Why forward
   passes.
3. **A file on disk** ("attach the report from Documents") — like case 2
   *only if nothing agentic ever wrote it*, and that can't be known:
   § Rejected.

## Rejected: attaching a file from disk (2026-11-24)

"Send Jana the October invoice" opens compose to Jana with the model's
text, and the user attaches `~/Documents/Invoices/2026-10.pdf` themselves.

- **Provenance is unknowable.** A pikuri-workspace `write` (this agent, a
  sub-agent, an earlier session), `bin/pikuri-files` with that folder
  writable, or a pikuri-workshop shell / coding agent writes the file
  first and attaches it "as an existing file" later — case 1, laundered
  through the filesystem across time. mtime loses to `touch -d`; a ledger
  of pikuri-workspace writes misses every other writer. Even
  `bin/pikuri-secretary`, whose Notes are the only writable folder, can't
  vouch for `~/Documents/Reports/q3.odt` that a workshop coding agent
  wrote last week.
- **The fix considered** was `Extension.new(attach_from: filesystem)`, a
  `Pikuri::Workspace::Filesystem` whose read-only part the host vouches no
  agent writes (not `trusted:`, which claims every byte user-authored and
  so excludes downloads). The user would vouch for what they can't check
  either ("anything an agent ever wrote into these folders can leave as an
  attachment you won't be able to inspect"); pikuri-thunderbird would gain
  a runtime dependency on pikuri-workspace, and core a review grade
  between seen and unseen (`:human_named`). All to save one drag into a
  window the user is already in to click Send.
- **A human picking the file is the strongest review there is:** pikuri
  ships none of its bytes. The model may still *name* a file to attach,
  steered by an injection, but then the user acts as themselves — the
  model can already ask that in chat today.
- So `thunderbird_mail_compose`'s description gains a Usage bullet: it
  can't attach files; when the user wants one sent, compose the message
  and tell them which file to attach in the compose window.

## Why forward passes where attach fails

"Why no attachments" sets the bar: an attachment fails because a careful
human *can't* catch the leak. A forwarded mail passes it. The compose
window's `<subject>.eml` chip opens on a double-click into the very copy
Send emits, the mail's own attachments listed and openable (§ Testbed
findings, 2026-11-24). Every byte in it is the sender's or the user's,
none the model's, so a leak there is overt, and a careful human who opens
it sees it. Two gaps remain: the bytes are a double-click away rather
than on screen (`Q_review_nudge`), and the copy is a writable file until
Send (`Q_staged_copy`).

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
| `-compose "…,attachment=file:///home/…/Documents/scan-receipt.png"` | **Attached**, under the file's own name and size, read straight from `~/Documents`: snap Thunderbird reads non-hidden `$HOME`, so no staging. (The shape § Rejected turns down.) |
| `-compose "type=1,originalMsgURI='…#3',body=…"` | **Thunderbird's own reply**: To from the original, `Re:` subject, `References`, Thunderbird's quote. **`body=` dropped**, in HTML and with `format=text`; `message=<file>` dropped too. A Thunderbird-made reply can't carry the model's draft. |
| `-compose "type=3,originalMsgURI='…',to=…,body=FYI"` | **Forward as attachment works.** `to` and `body` kept; Thunderbird attaches the original itself as `message/rfc822` "`<subject>.eml`", from a copy it stages (2026-11-24 below). The forwarded bytes never pass through the model. |
| `-compose "type=4,originalMsgURI='…',…"` | **Forward inline doesn't work**: an empty `Fwd:` with `References` and no original. Thunderbird starts an inline forward outside the compose window. |
| a staged `.eml` with `X-Unsent: 1` | **Opens as an editable draft** (`type` 9, plain text): To, Subject, `References` kept, From set to the identity, body verbatim. The MIME carries `References` + `In-Reply-To`. |
| `attachment=` a staged file, deleted before Send | **Send fails**: "Failed to fetch attachment" (`NS_ERROR_FILE_NOT_FOUND`). Thunderbird reads a file attachment at Send, not at attach, so a file pikuri stages must outlive the compose window, which may be hours or a pikuri restart away. |
| `message=` / `.eml` under the agent's `/tmp` | **Blocks**: snap Thunderbird has a private `/tmp`, so the file is "not found" and a *modal* alert opens. Stage in {Pikuri::Thunderbird::Profile#outbox_dir}, as the `.ics` hand-off does. |

### 2026-11-24: the forwarded chip

**How.** The same headless session, on INBOX#134 "Expenses for October"
(Ilse Berg, with `expenses-october.csv`). The double-click is
`dev/testbed/js/open-attachment.js`, a trusted one:
`window.synthesizeMouseEvent` at the chip's centre, mousedown/mouseup with
`clickCount` 1, then 2, as Mozilla's `EventUtils` does. A constructed
`MouseEvent` is untrusted and the chip's chrome listener ignores it;
`windowUtils.sendMouseEvent` is gone in 160.

| Check | Result |
|---|---|
| the `type=3` chip's URL | `file:///home/…/Downloads/thunderbird.tmp/pid-N/Expenses%20for%20October.eml`, **not** the `imap-message:` URI: Thunderbird stages the whole original, its attachments included, `0600` in the snap's `TMPDIR` (non-snap presumably `/tmp`; not tried). The copy goes when the compose window closes. |
| double-click the chip | **Opens the forwarded mail** in a `mail:messageWindow` on that copy: headers, body, and its own attachment list (`expenses-october.csv`). No prompt, no modal. The chip's `dblclick` (`attachment-list.mjs:193`) runs `cmd_openAttachment` → `OpenSelectedAttachment` (`MsgComposeCommands.js:9399`); Enter and right-click → Open run the same command. |
| edit the copy after the review, then generate Send's MIME | **The edit goes out**: Send reads the copy as it is at Send. |
| `-compose "to=…,attachment='imap-message://…#134'"` (no `type`) | Accepted — the compose window's `GetArgs` takes any non-file URI verbatim through `resolveURI` ("including web pages", says its comment) — but staged the same way, as "Attached Message", no `.eml`, no content type. No way around the copy; `type=3` stays. |

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
- So `-compose` becomes a second outbound transport beside `mailto:`, for
  forward only. Its key set is wider than mailto's five (`from`,
  `preselectid`, `format`, `newsgroups`, `attachment`, `message`, `type`,
  `originalMsgURI`, `bodyislink`), so it needs a builder like `MailtoUri`:
  allowlisted keys, every value percent-encoded so a body can't carry a
  raw `,` or `'` that starts a new `attachment=` pair. Enforced by
  construction, as today.

## Open questions

- `Q_trifecta_grade` — **decided 2026-11-24: forward is
  `:human_reviewed`**, by § Why forward passes; no new grade, no core
  change, and the secretary stays soft (`book/trifecta-detector.md`:
  "every way out either shown to you before it leaves or aimed where no
  attacker can read it"). Reply is too: its quote is on screen, and its
  headers carry only Message-IDs every recipient already has.
  {Pikuri::Tool::TrifectaLegs}' `:human_reviewed` ("the payload *is* the
  reviewed artifact") gains the second case, "or opens into it: a stored
  mail forwarded whole, none of whose bytes the model wrote". Considered:
  `:unreviewed` (a forwarding agent needs mail search, so the secretary
  would go loud); a middle `:human_named`, needed only by file attach,
  now rejected; a pikuri-built inline forward over `mailto:`, every byte
  on screen, but without the original's attachments, which are what most
  forwards are for. The `OUTBOUND_LEGS` yardoc ("would silently drop to
  hard `:egress`") needs rewording for the forward.
- `Q_review_nudge` — **decided 2026-11-24:** the forward tool urges the
  user to open the forwarded mail before Send, in both places it speaks.
  Its checklist (the result content, relayed by the model) names what
  leaves, from the mbox: the original's subject and sender, and its
  attachments by name and size, then "double-click `<subject>.eml` in
  the compose window to see exactly what goes". Its display line (the
  user sees it without the model in between) carries the same nudge,
  structural only — names are attacker-authorable, so counts and sizes,
  e.g. `Handed to Thunderbird: 1 mail with 2 attachments, 3.1 MB —
  double-click it before Send` ({Pikuri::Tool::Result}'s two rules). A
  bland subject over a sensitive file ("Lunch?" carrying
  `passport-scan.jpg`) is the case it's for.
- `Q_staged_copy` — **open.** Between review and Send the forwarded mail
  is a plain `0600` file under `~/Downloads/thunderbird.tmp/pid-N/`, and
  Send reads it as it is then, so a writer there swaps what the human
  approved. A process running uncaged as the user isn't new: it has its
  own way out. A *rooted* writer is: a `Pikuri::Workspace::Filesystem`
  whose writable roots cover `~/Downloads` (`bin/pikuri-files` rooted
  there is a natural "tidy my downloads"). In one agent with the forward
  tool that's model-written bytes leaving unseen; across agents it needs
  an injected file-tool turn while a forward sits open, and it leaks only
  what that writer reads. The secretary is clear: it writes only Notes.
  Options: (a) a wiring rule, stated in the Extension's yardoc and the
  threat model — never forward beside a Filesystem writable over
  `~/Downloads`; (b) pikuri-workspace refuses writes under
  `<Downloads>/thunderbird.tmp` — Thunderbird knowledge in a gem that
  doesn't otherwise have it; (c) the nudge says "just before Send",
  which shrinks the window but doesn't close it. Leaning (a) + (c).
- `Q_transport` — **decided 2026-11-23:** two transports, one per tool,
  forced by the shapes above (only `mailto:` threads a reply that keeps a
  body; only `-compose` forwards as attachment). Reply →
  {Pikuri::Thunderbird::MailtoUri}, whose allowlist gains `In-Reply-To` /
  `References`. Forward → a new `ComposeArgs` builder: allowlist `to cc
  bcc subject body type originalMsgURI`, never `from preselectid format
  message newsgroups bodyislink`, and never `attachment`, which resolves
  any URI, a web page included; every value percent-encoded, unquoted (no
  raw `,` or `'` can open a key; `originalMsgURI`'s `%40` round-trips as
  `%2540`); `type` from a fixed set, never from the model.
  `Launcher#launch` takes an argv. Compose stays on `mailto:`.
- `Q_reply_shape` — **decided 2026-11-23:** a separate
  `thunderbird_mail_reply(message_id:, body:, reply_all: false)` over
  `mailto:`. pikuri derives everything but the body from the original: the
  recipient (`Reply-To`, else `From`; plus the other recipients under
  `reply_all`), `Re: <subject>`, `In-Reply-To` and the original's own
  `References` chain from the mbox, and an "On … wrote:" `> ` quote under
  the model's text. The model never names a reply's recipient. Rejected:
  `in_reply_to:` on `thunderbird_mail_compose` (the model still names the
  recipient, four fields to keep consistent); `-compose type=1` as the
  main shape (drops the model's text; maybe later as "open the reply for
  me").
- `Q_guard_on_quotes` — **decided 2026-11-23:** ComposeGuard checks the
  model's text only; the quote is appended after the verdict, verbatim
  from Gloda's body, `> `-prefixed, never filtered. Safe because of a rule
  the reply tool states as its own: **a reply adds no recipient the
  original didn't name** (no `cc:`), so every recipient already holds the
  original and the quote — hidden bytes included, the author's own — tells
  no one anything new. A future `cc:` must bring the quote under the guard.
  The quote is capped (~4 KB of the original's text, cut at a line, ending
  `[…]`): Linux caps one argv string at 128 KiB (`MAX_ARG_STRLEN`) and
  percent-encoding inflates non-ASCII up to 9×; threading lets the
  recipient's client show the rest. Still refused: the model pasting
  hostile lines into its own text (`warn-human-directly.md`).
- `Q_forward_scope` — **decided 2026-11-23, kept 2026-11-24:**
  `thunderbird_mail_forward(message_id:, to:, body:, cc:)` forwards the
  whole mail as an attachment through `-compose type=3`; the model writes
  the note and names `to`, which ComposeGuard checks as for compose.
  Thunderbird stages the original itself and reaps it with the window.
  Deferred: one attachment of a mail (`"2.1"`) — pikuri would stage its
  bytes in the outbox, and since Thunderbird reads a file at Send, no
  moment is safe to reap it. The chip turned out to open into what
  leaves, so `Q_trifecta_grade` settled without reopening this.
- `Q_display_run` — re-run both tables through the real `setsid
  thunderbird …` remoting in a `--display` session (`DISABLE_WAYLAND=1`,
  architecture.md § The testbed); the modal-alert cases and the chip's
  double-click matter most there, since a human meets them.
- `Q_doc_order` — rewrite the invariant now, or after the testbed has
  answered the mechanics questions?

## On graduation

The invariant narrows to "the only attachment that ships is a stored mail
Thunderbird forwards itself" in the five places that state it:

- `pikuri-thunderbird/AGENTS.md` § Invariants
- `pikuri-thunderbird/design/architecture.md` § "Outbound is a human-gated
  hand-off" and § "Why no attachments"
- `pikuri-thunderbird/lib/pikuri-thunderbird.rb`, `OUTBOUND_LEGS`' yardoc
- `book/secretary.md` (~l. 384)
- `book/trifecta-detector.md` (~l. 415)

Also: {Pikuri::Tool::TrifectaLegs}' `:human_reviewed` and
`book/trifecta-detector.md` gain "or opens into it"; compose's
description gains the can't-attach bullet. The why (authorship vs.
selection, the provenance gap, why file attach is the user's job, why the
forwarded chip passes the careful-human bar) → a `D_` entry in
`design/decisions.md`; the § Testbed findings tables → architecture.md
§ Hand-off mechanics, for the shapes that ship, and the trusted-click
mechanics → § The testbed's Marionette bullets; a CHANGELOG line.
