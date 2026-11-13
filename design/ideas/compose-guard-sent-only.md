# The compose guard's novelty check: count only domains Alex has sent to

Status: **decided 2026-11-13, not built.** Blocks the secretary chapter's compose-guard scene
([`book-rework.md`](book-rework.md)).

## The problem

`Gloda::Contacts#domains_seen` asks Gloda's `identities` table whether a domain is known, and
that table holds every author as well as every recipient. So a domain that only ever wrote *to*
the user counts as seen the moment its mail is indexed. On the testbed
(`pikuri-thunderbird/design/architecture.md` § The testbed) the look-alike
`northwlnd-bank.example`, the never-written-to `design-week.example` and the attacker's
`kettle-co-payments.example` all came back "seen". The novelty warning therefore never fires
on a reply to a phishing mail, or to any new sender, which is exactly when it matters: an
attacker earns "seen" by writing first.

## Decided

Count only domains the user has **sent** mail to: recipients of messages in the Sent folder(s)
(or authored by one of the user's identities). A received mail proves nothing about its sender.

## To work out while building

- Which query: Gloda's identities joined to messages authored by the owner's identities, or
  `c4recipients` of messages whose author is an owner identity? The owner's identities come from
  `prefs.js` (`mail.identity.*.useremail`) or Gloda's own "me" contact.
- A user who never keeps Sent mail (some IMAP setups) gets a warning on every recipient. Say so
  in the warning, or detect an empty Sent and degrade to the current answer with a note?
- The contract change lands in `domains_seen`'s and `ComposeGuard`'s yardoc, with a spec that
  builds a Gloda where a domain only authored mail.
- Check on the testbed: a reply to `design-week.example` warns, a reply to `lumo-studio.example`
  (Alex wrote to Mira) doesn't.
