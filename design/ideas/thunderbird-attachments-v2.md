# Thunderbird attachments: what v1 left out

`thunderbird_mail_attachment_read` reads an attachment's text (v1, see
`pikuri-thunderbird/design/architecture.md`). These are refused today, each
with a message saying so; build one only when it is asked for.

## Images (`Q_images`)

`read` attaches PNG/JPEG/GIF/WebP as a `RubyLLM::Attachment`, which needs a
file path, so the decoded bytes would be staged under `Paths.new_temp` (`0700`,
reaped at exit) — a new at-rest copy, but at the snapshot's trust level. 54 of
the IMAP account's attachments were images, mostly inline logos. Reuse
`Workspace::Read`'s size cap and its "Read image: …" note shape.

## Forwarded mails (`message/rfc822`)

Render as headers + text body via the same `mail` gem walk: its encoded-word
decoding is what stdlib lacks, and the reason the gem was taken over a
hand-rolled walker. Gloda records every such part with `size` `0`. Its
*nested* attachments need a path handle (`2.1`), not the flat index the
listing gives, so they are a step after that.

## Maildir and other stores

`MessageStore` raises on a non-`berkeleystore` server. Maildir is one file per
message under `cur/`: scan headers for the Message-ID, or use the `storeToken`
filename if `.msf` is ever read. Folder names with filesystem-illegal
characters get hashed by Thunderbird (`NS_MsgHashIfNecessary`); unhandled
until a real folder hits it.

## Smaller ones

- **Extraction timeout (`Q_extract_timeout`).** None today: Ruby's `Timeout`
  is unsafe around native code, pikuri-pdf parses pages lazily, and the 40 MB
  message cap bounds the input. Revisit if a hostile PDF ever hangs a turn.
- **Paging the body.** `thunderbird_mail_read` still hard-truncates a body at
  40 KB; it could take `offset`/`limit` and answer through
  `Tool::Result.page` like the attachment reader does.
