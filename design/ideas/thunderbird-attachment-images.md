# Thunderbird attachments: let the model see an image

`thunderbird_mail_attachment_read` refuses `image/*` up front ("is an image,
which can't be read yet"). Lift that: answer the image itself, so a vision
model sees the pixels and a text-only one gets a note why it doesn't.

## What the testbed showed (Thunderbird 159, POP3, 2026-11-14)

- **Which images Gloda lists.** An image attached outright (`multipart/mixed`,
  `Content-Disposition: attachment`) and one `inline` under `mixed` (Apple Mail
  style) are both in `attachmentInfos`, Gloda's size equal to the decoded size.
  An image an HTML part shows by `cid:` inside `multipart/related` is **not
  listed at all** — neither under `alternative` (the floor-plan scene) nor as
  the root of an HTML-only mail. So the tool can only ever reach the first two
  kinds; embedded logos stay invisible, which is probably what we want.
- The v1 note "54 of the IMAP account's attachments were images, mostly inline
  logos" doesn't square with that: those logos must sit in some other MIME
  shape, or IMAP / an older Thunderbird lists them. Worth one look on the real
  box (by the user — never pull real mail into a session).
- **The read path already works.** The existing `mail`-gem walk decodes both
  listed images to valid PNG bytes (`89504e47…`), binary-encoded. No staging on
  disk: `Pikuri::Attachment` holds the bytes.

## What the model gets — nothing new in core

The tool answers `Tool::Result.new(content: note, attachments: [image])`.
`Tool#to_ruby_llm_tool` already carries it: ruby_llm sends the image as a
`:user` message ("Attachments from tool call <id>:") after the tool result;
a model whose `/props` says no vision gets the note plus
`[x.png not shown: model … takes no vision input]` instead of an HTTP 500
(`D_refuse_unsupported_attachments`). The tool never asks which model it serves.

## Sketch

In `MailAttachmentRead.run_read`, before `extract`:

```ruby
bytes = attachment_bytes(store, rec, att)
mime  = Pikuri::FileType.detect_mime(bytes)          # core; PNG/JPEG/GIF/WebP by magic
return image_result(att, bytes, mime) if mime&.start_with?('image/')
```

`image_result` caps the size, builds
`Pikuri::Attachment.new(mime:, filename: att.name, bytes:)` and a note shaped
like `Workspace::Read`'s: `Read image: cottage.png (398 bytes, image/png)`.
The refusal arm for `image/` goes; the tool description's "Images … can't be
read here" line flips to "Images come back as pictures you can see (needs a
vision-capable model)".

Testbed: add a scene with an image attached outright (the builder needs a
`png:` attachment source; `Png.named` already draws `chata-1` / `chata-2`).
A spec drives `run_read` on it and asserts the `Attachment`'s mime and magic.

## Open questions

- `Q_image_sniff` — trust the magic bytes or Gloda's type? Magic, like
  `Workspace::Read`: Gloda's type is guessed from a sender-authored file name.
  So an `image/png` whose bytes aren't an image falls through to the text
  extractors (and their binary refusal), and a `.bin` that *is* a PNG shows as
  one. Then the up-front refusal by type goes entirely.
- `Q_image_cap` — the 5 MB cap lives in `Workspace::Read::MAX_IMAGE_BYTES`, and
  pikuri-thunderbird must not depend on pikuri-workspace for a constant. Move
  it to core (beside `Pikuri::Attachment`, it's the provider's per-image limit,
  not a workspace rule), or keep a second copy here? Lean: core.
- `Q_image_formats` — HEIC (iPhone photos) and TIFF/BMP aren't sniffed and no
  provider takes HEIC. Refuse with "a HEIC photo, which can't be shown" or let
  it fall through to the generic no-reader error? Lean: the generic error,
  until a real mail hits it.
- `Q_image_paging` — `offset` / `limit` mean nothing for an image; ignore them
  silently (as `Workspace::Read` does) or error? Lean: ignore.

## Threat model

No new leg: an image is untrusted content like a PDF, same `INBOUND_LEGS`. But a
vision model reads text *drawn* into a picture, which nobody reviews and no
filter sees — the same severity note `architecture.md` already makes for
attachments ("raise severity, not the leg count"); add images to it on
graduation. The decoder is the provider's / llama.cpp's, not ours — pikuri
never parses the image.
