# A local IMAP account in the Thunderbird testbed

Status: **deferred.** The testbed (`pikuri-thunderbird/design/architecture.md` § The testbed)
has one POP3 account, which stores plain mbox under `Mail/`.

The owner's real setup is IMAP (Gmail, iCloud), and the POP3 account exercises neither
`MessageStore`'s `ImapMail/` path, where `messageKey` is the IMAP UID, nor attachments IMAP
fetches only on demand. A second account against a local dovecot (apt) would cover both; the
mbox it serves would come from the same `mail.yml`.
