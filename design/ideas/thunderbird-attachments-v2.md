# Thunderbird attachments: what v1 left out

`thunderbird_mail_attachment_read` reads an attachment's text (v1, see
`pikuri-thunderbird/design/architecture.md`). What it still can't do, each
answered with a message saying so; build one only when it is asked for.

## Forwarded mails: their own attachments

A forward now reads as its headers, attachment list and text
(`Pikuri::Thunderbird::ForwardedMail`, 2026-11-14). Its attachments are only
*listed* ("open them in Thunderbird"), and that is the remaining gap: Gloda's
FTS `c2attachmentNames` carries the names inside a forward, so searching "CV"
finds `application-fwd`, and the CV can then be seen but not read.

Next step: number the forward's list and take a path handle,
`attachment: "1.2"` (forward 1, its attachment 2); the parameter becomes a
string, `"3"` still works. The walk then descends by path, so forwards of
forwards come free.

- **Handle: decided, the path** (2026-11-14), over a second integer param
  (`attachment: 1, inner: 2`): one param, any depth. The parameter
  description carries an example value (`"1.2"`), since the integer pair
  would have been the more obvious schema for a small model. On graduation
  this becomes a `D_` entry.
- **The listing is settled, so its numbers can become handles**
  (2026-11-14). `ForwardedMail` lists what Gloda lists for the same tree at
  top level. The testbed checks that for Apple Mail, Outlook and odd-leaf
  trees, from hand-written `.eml` fixtures (the rule:
  `pikuri-thunderbird/design/architecture.md` § "What `attachmentInfos`
  lists"). Those trees rest on what the clients are documented to write; a
  shape found in the wild becomes another fixture.

The testbed's forwards: `application-fwd` (a `.docx` inside), `venue-fwd`
(an image), `floor-plan-fwd` (a `cid:` image that stays body),
`application-fwd-fwd` (a forward of a forward), and `venue-quote-fwd`,
`claim-form-fwd`, `statement-fwd` (the other clients' trees). Each of the
last three has its original in the Inbox, so
`pikuri-thunderbird/dev/testbed/compare-forwards` checks them against Gloda;
re-run it once the listing is numbered. The path handle's spec should read the CV through `application-fwd`
(`"1.1"`) and `application-fwd-fwd` (`"1.1.1"`), and Apple Mail's PDF
through `venue-quote-fwd`.

## Smaller ones

- **Hashed folder names.** Thunderbird hashes a folder name with
  filesystem-illegal characters into its mbox file name
  (`NS_MsgHashIfNecessary`); `MessageStore` maps the name verbatim.
  Unhandled until a real folder hits it.
- **Extraction timeout (`Q_extract_timeout`).** None today: Ruby's `Timeout`
  is unsafe around native code, pikuri-pdf parses pages lazily, and the 40 MB
  message cap bounds the input. Revisit if a hostile PDF ever hangs a turn.
