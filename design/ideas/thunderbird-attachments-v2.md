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
- `Q_fwd_listing_policy` — `ForwardedMail` mimics Gloda's rule (body = what
  sits under `alternative` / `related`, plus unnamed text/plain and text/html
  leaves), verified against the testbed and a synthetic spec, never against a
  real Outlook / Apple Mail forward. Check on the real box before numbering,
  since the numbers become handles.

The testbed covers the shapes (2026-11-14): `application-fwd` (a `.docx`
inside), `venue-fwd` (an image inside), `floor-plan-fwd` (an HTML mail whose
`cid:` image must stay body) and `application-fwd-fwd` (a forward of a
forward). Live, each lists what Gloda would. The path handle's spec should read the
CV through `application-fwd` (`"1.1"`) and `application-fwd-fwd` (`"1.1.1"`).

## Smaller ones

- **Hashed folder names.** Thunderbird hashes a folder name with
  filesystem-illegal characters into its mbox file name
  (`NS_MsgHashIfNecessary`); `MessageStore` maps the name verbatim.
  Unhandled until a real folder hits it.
- **Extraction timeout (`Q_extract_timeout`).** None today: Ruby's `Timeout`
  is unsafe around native code, pikuri-pdf parses pages lazily, and the 40 MB
  message cap bounds the input. Revisit if a hostile PDF ever hangs a turn.
