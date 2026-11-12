# Thunderbird: render HTML mail attachments

Since `a98f53f` the HTML → Markdown extractor is `Pikuri::Web::HTML` in pikuri-web, registered by
`require 'pikuri-web'`. `thunderbird_mail_attachment_read` passes the attachment's MIME type to the
`Pikuri::Extractor` registry, so a `text/html` attachment now reads as raw markup through
`Passthrough` unless the host happens to load pikuri-web. `bin/pikuri-thunderbird` doesn't.

Raw markup is readable to a model but noisy: a newsletter-style HTML attachment is mostly inline
CSS, tables and tracking pixels, and burns context. Rendered Markdown is what the user wants
(IMHO, says the owner). HTML attachments are common: forwarded receipts, invoices, booking
confirmations, "view this message as a web page" exports.

Only the *attachment* path is affected. Message bodies come from Gloda, already HTML-stripped
(`thunderbird_mail_read`).

## Options

1. **The host requires pikuri-web.** `bin/pikuri-thunderbird` adds `require 'pikuri-web'` and wires
   no web tool. Zero new code, and no egress, since loading isn't wiring. But the demo then loads
   code the agent never runs (against `D_read_what_you_run`), and a reader auditing an "offline"
   mail agent sees `pikuri-web` and has to check that nothing is wired. The gem's name says "reaches
   the internet", which is exactly what this agent refuses to do.
2. **pikuri-thunderbird depends on pikuri-web.** The same as 1, but forced on every host. Worse:
   the dependency points from a local-only gem to a network gem.
3. **Split a `pikuri-html` gem out of pikuri-web**, holding only `HTML` plus nokogiri,
   ruby-readability and reverse_markdown, and registering on require. pikuri-web depends on it,
   and pikuri-thunderbird (or just its host) does too. Clean dependency direction, but does it earn
   a gem? "A gem is earned by a *novel* threat model or cohesive lib code needing a home": one file
   is a thin claim, though "parse untrusted HTML with a native extension" is a real audit surface
   of its own.
4. **pikuri-extractors claims `text/html` too.** markitdown already converts HTML. But it means a
   docker round-trip per small HTML part, and only for hosts that wire pikuri-extractors.
5. **Explicit registration instead of on-require**, making `Pikuri::Web::HTML.register` (or the
   `pikuri-html` one) a host call like `Pikuri::Extractors::PDF.register`. This is independent of
   1–4, and only changes who flips the switch.

Leaning: **3**, if a second offline consumer ever appears (a vectordb corpus of saved pages would
be one, but that also needs a `FileType` rule, since local files never carry `text/html`). Until
then **1** is the cheap experiment.

## Open questions

- `Q_hidden_text`: rendering can *hide* what raw markup shows. Readability drops boilerplate, but
  does it drop `display:none` / zero-size / white-on-white text? A prompt injection hidden that way
  would be read by the model under both renderings, but only the raw one lets a human reviewing
  the transcript see it's styled invisible. Check what `Web::HTML` does with a hidden span, and
  whether that matters for a tool whose output only the model reads. The trifecta legs are the
  same either way: the attachment is already untrusted inbound text.
- `Q_readability_on_mail`: readability is tuned for article pages. On a receipt or a booking
  confirmation (layout tables, no `<article>`), does it keep the line items, or collapse to the
  title? Try it on a few real attachments from the IMAP account before committing to rendering.
- `Q_inline_vs_attachment`: does Gloda ever list a `text/html` alternative *body* part as an
  attachment? If so, the attachment reader would re-read the body in its HTML form. Check what
  `attachmentInfos` holds for a multipart/alternative mail.
- `Q_where_the_require_lives`: with option 1, does the require go in the bin script only, or does
  `Pikuri::Thunderbird`'s yardoc tell every host to do it?

Related: `design/ideas/thunderbird-attachments-v2.md` (other formats v1 left out).
