# Strip Gloda's literal `undefined` from author and recipient text

Status: **decided 2026-11-13, not built.**

Thunderbird 159 writes `Mira Koskinen <mira@lumo-studio.example> undefined` into
`messagesText_content.c3author` / `c4recipients` for every address but the owner's own as author
(`pikuri-thunderbird/design/architecture.md` § Mail: the Gloda index). pikuri hands it to the
model as it is.

**Decided: the readers strip it**, whatever the owner's real profile shows: the model would echo
or interpret it, and it costs tokens per address. Match only ` undefined` right after an
address's closing `>`, so a person named "Undefined" survives; the `from:` / `to:` LIKE filters
are unaffected.

Still to record, for the yardoc's wording only ("Thunderbird 159 writes…" vs "Gloda writes…"):
whether the owner's real profile has it too. A count, no mail content, run by the owner on their
own machine: `SELECT count(*) FROM messagesText_content WHERE c3author LIKE '%> undefined%'`.
