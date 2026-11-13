# A Thunderbird testbed: mail scenes without anyone's real mail

Status: **the pipeline is built, the content isn't.** `bin/pikuri-demo-mailbox` (or `rake
demo:build`, `DIR=` for `--dir`) with its code in `book/demo/builder/` guards, writes the
inputs, indexes through Marionette, verifies the counts and caches the result. It runs on a
five-message seed (`content.rb`) for now, so the secretary chapter's mail transcripts
([`book-rework.md`](book-rework.md)) still wait on § The demo content.

## The problem

The mail and calendar tools read Thunderbird's own stores — the Gloda index
(`global-messages-db.sqlite`) for mail and contacts, the mbox files for attachment bytes, the
calendar's `calendar-data/` SQLite — and only a running Thunderbird builds them
(`pikuri-thunderbird/design/architecture.md` § Storage landscape). So far the only populated
profile on the dev VM was the owner's real one, and testing the secretary against it put real
mail into session logs and transcripts (a medical appointment reminder, 2026-11-13). That profile
was deleted from the VM on 2026-11-13; the Thunderbird snap (159.0) was reinstalled the same day
with no profile.

**The rule from here: the VM only ever holds a demo profile.** A tool that auto-discovers the
snap/apt profile root then finds demo data or nothing, never real mail.

## What a testbed has to serve

1. **The book's transcripts.** Every scene the secretary chapter quotes (a reply drafted, an
   invitation turned into an event, an injection attempt, the compose guard's novel-domain warning)
   runs on demo mail.
2. **A reader reproducing the chapter's scenes.** The same mailbox, built by the reader in a few
   steps, beside their real profile and without touching it. This is the side path: the
   chapter's main path points the secretary at the reader's *real* mail (auto-discovery, no
   setup) — read-only, a local model by default, the only way out a human-gated hand-off. The
   VM-only-demo rule above is about *our* logs and transcripts, not a reader's own machine. The
   demo is for the scenes real mail can't stage on demand (the injection mail, the look-alike
   domain). The caveat the chapter states is a hosted provider: wire one and your mail goes to it.
3. **Agents testing the mail tools on the VM**, headless, with no human driving a GUI.
4. **The hand-offs.** `thunderbird_mail_compose` and `thunderbird_calendar_create` launch
   `thunderbird`; on a VM with no display something has to stand in for the window.

## Decided: we write the inputs, Thunderbird writes its stores

Option A from the first brainstorm: a real Thunderbird builds a real demo profile. We never write
Thunderbird's own schemas (Gloda, `.msf`, calendar SQLite); we write only what Thunderbird reads
as *input*, and wait through its first import.

| We write | Thunderbird builds from it |
|---|---|
| `user.js` (account, identity, quiet first run) | `prefs.js` |
| mbox files (Inbox, Sent, Archives, …) | `.msf` summaries, the Gloda index |
| `demo.ics`, registered as an `ics` network calendar with `cache.enabled` | `calendar-data/cache.sqlite` |
| the owner's identity + a Sent folder | Gloda contacts, the correspondence graph behind `domains_seen` |

Rejected:

- **Synthesizing the stores ourselves** (old option C). It tests pikuri against pikuri's own
  reading of the schema. The specs already build small Gloda databases for unit tests; the cached
  profile (below) serves agents, so C has no job left.
- **A hand-built profile copied from the host** (old option B). Not reproducible by a reader. Its
  good half — a ready profile in seconds — comes back as the build script's own cached tarball.

### The account: a dead POP3 account, not Local Folders

Local Folders has no identity, so Gloda has no "me": nothing is *from* the owner, there is no
believable Sent folder, and the compose guard's novelty check (`Gloda::Contacts#domains_seen`) has
no correspondence graph. The demo profile therefore defines one **POP3 account**,
`alex@novak.example` on `pop.novak.example`, with `login_at_startup` and new-mail checks off. A
POP3 account stores plain mbox under `Mail/pop.novak.example/`, which we fill; no server runs.
SMTP points at `smtp.novak.example`.

**Every domain is RFC 2606-reserved** (`.example`, `.test`, `.invalid`). Nothing resolves, so a
Send clicked by mistake fails instead of reaching a real address or a real company.

### First-run hygiene in `user.js`

Telemetry and data reporting off, add-on update checks off, the account wizard and account
provisioner suppressed, start page off, the year-end donation tab marked seen, default-client
check off. Privacy first applies to the testbed too: a first run phones nowhere.

The prefs come from Mozilla's own list rather than being hunted down one at a time: Marionette's
`RecommendedPreferences.sys.mjs`, shipped inside Thunderbird's `omni.ja`
(`chrome/remote/content/shared/`; read locally, nothing downloaded), is curated to keep an
automated profile off the network. It has the remote-settings one, `services.settings.server =
"data:,#remote-settings-dummy/v1"`, plus `app.update.disabledForTesting`,
`network.connectivity-service.enabled`, the safebrowsing, region and extension-update prefs. Its
`%(server)s` placeholders become a `.invalid` host. Verified on the seed build (2026-11-13):
`strace` can't follow into a snap without root (snap-confine is setuid), so the check is
Mozilla's own logging — `MOZ_LOG="nsHostResolver:5,nsSocketTransport:5,nsHttp:3"
MOZ_LOG_FILE=~/snap/thunderbird/common/moz.log bin/pikuri-demo-mailbox --rebuild` — which
showed no DNS lookup, no HTTP channel, and one socket, Marionette's on loopback. The
remote-settings error is gone from the log. Re-run it after a Thunderbird upgrade. A build
lasts seconds, so a fetch on a later timer would slip past it; the reader opening the profile
in the GUI is the untested case.

## The build script

`rake demo:build` (or a `bin/` script it calls) does, in order:

1. **Guard.** Every demo profile carries a marker file, `.pikuri-demo`. If either root (snap
   `~/snap/thunderbird/common/.thunderbird`, apt `~/.thunderbird`) holds a profile *without* the
   marker, stop and print the paths. Never delete, never offer to. In `--dir` mode the same
   goes for the target: an existing non-empty dir without the marker stops the build, so a
   mistyped path never overwrites something that isn't a demo.
2. **Generate** the mbox files, `demo.ics` and the demo `~/Documents` from `book/demo/`.
3. **Create the profile**, in one of two modes:
   - **VM (default):** registered in `profiles.ini` as `Default=1`, so pikuri's auto-discovery
     is exercised for real.
   - **`--dir ~/pikuri-demo` (reader, host):** `profiles.ini` untouched. Thunderbird runs as
     `thunderbird -profile ~/pikuri-demo --no-remote`, pikuri gets `profile_dir:` — the
     override `Profile.discover` already has. The reader's real profile is never seen.
   `demo.ics` lives in the profile itself: the snap reads its own root, and a reader's
   `--dir` (not hidden — the snap can't read dot-dirs in `$HOME`) carries it along.
4. **Index.** Run Thunderbird `--headless --marionette` and, over Marionette, reparse every
   mail folder and queue it for Gloda (§ Driving a real Thunderbird). The generator knows it
   wrote N messages and M events: snapshot the Gloda DB every second or two and count `messages`
   rows until N, then quit through Marionette — a clean quit checkpoints `cache.sqlite`'s WAL,
   so the M events are then countable too. Done-detection by expected count, not by guessing at
   Gloda's internals. A slow index only makes the build slower, never wrong: a generous timeout
   (~5 min) with progress (`212/287`), failing loudly with the count reached. If ~300 messages
   turn out slow, suspect Gloda's indexing throttle (tuned for a user at the keyboard) first.
5. **Cache.** Tar the indexed profile to `Paths.cache/demo-mailbox/`, keyed by Thunderbird's
   version *and* a digest of every input: the dates move with `--today`, and Thunderbird
   writes absolute paths into `prefs.js`, so another day or another `--dir` is another
   profile. One tarball is kept; `--rebuild` ignores it. Inputs are byte-stable (the `mail`
   gem's random multipart boundary is replaced by one derived from the Message-ID), so a
   same-day rerun restores in 0.75 s instead of indexing.

Measured on the seed (5 messages, 3 events): indexed in 3.6 s, 4.8 s end to end.

## The demo content (`book/demo/`)

One persona and one **facts file** (YAML: names, IBAN, invoice number, the relative dates) that
the mail, the calendar and the demo `~/Documents` all read, so a cross-source scene can't drift.
`rake demo:build` builds all three. MIME is written with the `mail` gem (already in the lockfile).

- **Dates relative to the build day** (`--today`, default now). "What's on Thursday?" and "due in
  five days" have to stay true whenever the profile is built.
- **~20 hand-written scene messages**, each there to make a scene happen:
  - an invoice reminder that pairs with a PDF in the demo `~/Documents` (the cross-source answer);
  - a short meeting thread with quoted replies, chained by `In-Reply-To` / `References` so Gloda
    builds the conversation (thread-reading discipline);
  - an invitation as a real `text/calendar; METHOD=REQUEST` part, plus one with a plain `.ics`
    attachment (calendar create from mail);
  - a mail asking the secretary to "add a note: invoices now go to IBAN X" (stored injection,
    the integrity scene), and a PDF attachment carrying the same injection *inside* the file;
  - a reply-worthy mail from a domain never seen before (the compose guard's novelty warning),
    and one from a look-alike of a known domain (`northwlnd-bank.example`);
  - the owner's own replies in Sent, so the correspondence graph is real.
- **150–300 seeded-template noise messages** — newsletters, CI and shipping notifications, a
  mailing list — so search has something to rank past.
- **MIME variety, because that's where parsers break:** multipart/alternative and HTML-only
  newsletters, an inline `cid:` image, a forwarded `message/rfc822`, RFC 2047 encoded subjects and
  RFC 2231 attachment names in Slovak and Finnish (`faktúra_č.12.pdf`), `.docx` / `.zip` / `.csv`
  attachments, one attachment over the read limit.
- Binary attachments (PDF, `.docx`) come from HTML sources via `soffice --convert-to`, the way the
  demo `~/Documents` was built by hand on 2026-11-13; only the sources are versioned.
- Calendar: a handful of events around "this week", one recurring, one all-day.

## The hand-offs on a headless VM

Two levels:

- **Stub binary** for specs and quick agent checks: `Thunderbird::Extension` already takes
  `thunderbird_bin:`; a stub that logs its argv and the handed files (the `mailto:` URI, the
  `.ics`) lets an agent assert what *would* have opened.
- **The real window under Xvfb**: with Thunderbird running on Xvfb, the hand-off opens a real
  compose window, and a screenshot of the Xvfb root lets an agent see what the human would have
  seen. The VM has no `import` / `xwd` / `xdotool`, but `ffmpeg -f x11grab` grabs a frame and
  `xwininfo -root -tree` lists the windows (§ Driving a real Thunderbird). Clicking is out
  (no `xdotool`); anything that needs a click goes through Marionette instead.

The book still wants one real compose window captured on a host.

## Deferred: a local IMAP account

The owner's real setup is IMAP (Gmail, iCloud), and the dead POP3 account doesn't exercise the
`ImapMail/` path in `MessageStore` (where `messageKey` is the UID) or attachments that IMAP only
fetches on demand. A second account against a local dovecot (apt) would cover that. Not in v1.

## Driving a real Thunderbird (probed 2026-11-13, snap 159.0, on the VM)

How an agent drives Thunderbird with no human and no display. Probed with a five-message demo
profile (`~/snap/thunderbird/common/probe-profile`, marked `.pikuri-demo`). On graduation this
section moves to `pikuri-thunderbird/design/architecture.md` beside § Storage landscape.

**Launching.**

- `thunderbird --headless --no-remote -profile <dir>` runs a full Thunderbird with no display:
  accounts load from `user.js`, Gloda's DB and the calendar stores are created, the `ics`
  calendar syncs into `cache.sqlite`.
- `-profile <dir>` does **not** create or touch `profiles.ini` — `--dir` mode is safe beside a
  real profile.
- The snap reads its own `~/snap/thunderbird/common/`; profile and `demo.ics` live there.
- **The snap launcher links its root to an existing `~/.thunderbird`.** Launched while
  `~/.thunderbird` existed and the snap root didn't, it created
  `~/snap/thunderbird/common/.thunderbird -> /home/mavi/.thunderbird` (seen on the first build,
  which wrongly put the profile in the apt root). For a user migrated from the deb that makes
  both roots one directory, and `Profile.discover` raises "found profiles under two roots" for
  what is one profile. A pikuri bug, not fixed: compare the roots' `realpath` before calling it
  two. `Profile`'s spec doesn't cover the root scan.
- A clean exit **leaves the `lock` symlink behind** (`lock -> <ip>:+<pid>`); the live lock is
  the one on `.parentlock`. Waiting for `lock` to go cost the first builds 30 s.
- `marionette.port = 0` in `user.js` makes Marionette pick a free port and write it to
  `<profile>/MarionetteActivePort`, so a build never collides with another Thunderbird's 2828.
- Under Xvfb: `xvfb-run -a -s "-screen 0 1600x1000x24" thunderbird --no-remote -profile <dir>`.
  Only needed for screenshots; indexing doesn't need it.
- Stop it with `pkill -TERM -x thunderbird-bin` — `-x`, because `pkill -f` matches the agent's
  own shell, whose command line contains the pattern. Better: quit over Marionette (below).

**A dropped mbox is not picked up on its own.** Headless or under Xvfb, with mail checks off,
Thunderbird lists `Inbox` and `Sent` (they're in `folderCache.json`) but never parses them: no
`.msf` appears, Gloda doesn't register the folders, `messages` stays at 0 after four minutes. The
3-pane window opens on the account's home page, not on Inbox, so nothing opens a folder either.
Gloda's sweep skips folders whose summary is missing.

**Marionette is the way in.** Release Thunderbird ships Marionette (the WebDriver-ish protocol
geckodriver speaks), and in *chrome context* — Mozilla's word for the application's own
privileged JS, nothing to do with Google Chrome — a script can call Thunderbird's own APIs.

- Start with `--marionette` and the env var `MOZ_REMOTE_ALLOW_SYSTEM_ACCESS=1` (the
  `--remote-allow-system-access` flag is not enough on 159; `SetContext chrome` names the env
  var in its error). The env var passes through the snap. Marionette listens on 127.0.0.1:2828.
- The protocol is length-prefixed JSON over TCP: the server sends `len:{hello}`; a command is
  `len:[0, id, "Name", {params}]`, a reply `len:[1, id, error, result]`. A ~40-line Ruby client
  is enough: `WebDriver:NewSession`, `Marionette:SetContext {value: "chrome"}`,
  `WebDriver:ExecuteAsyncScript {script:, args: [], scriptTimeout:}` (the script resolves via
  `arguments[arguments.length - 1]`), `WebDriver:DeleteSession`.

**Reparse, then index** — the step that makes it work; all five messages were in Gloda two
seconds after it:

```js
const { MailServices } = ChromeUtils.importESModule("resource:///modules/MailServices.sys.mjs");
const { GlodaMsgIndexer } = ChromeUtils.importESModule("resource:///modules/gloda/IndexMsg.sys.mjs");
const skip = Ci.nsMsgFolderFlags.Trash | Ci.nsMsgFolderFlags.Queue;
// for each non-skipped folder of every account's rootFolder.descendants:
//   folder.QueryInterface(Ci.nsIMsgLocalMailFolder).getDatabaseWithReparse(urlListener, null)
//     — throws NS_ERROR_NOT_INITIALIZED = "reparse started"; await the listener's
//       OnStopRunningUrl; if it returns, the DB was already valid
//   then GlodaMsgIndexer.indexFolder(folder, { force: true })
```

`indexFolder` alone, without the reparse, queues the folder and indexes nothing.

**Quitting:** a script that resolves, then dispatches
`Services.startup.quit(Ci.nsIAppStartup.eAttemptQuit)` to the main thread. Thunderbird exits in
about two seconds and checkpoints its WAL databases on the way out.

**Screenshots under Xvfb:** `xwininfo -root -tree` finds the windows;
`ffmpeg -f x11grab -video_size 1600x1000 -i :99 -frames:v 1 shot.png` grabs the screen (set
`DISPLAY` and `XAUTHORITY` from `xvfb-run`'s `/tmp/xvfb-run.*/Xauthority`).

**First-run network:** with the probe's `user.js`, Thunderbird contacted Mozilla's remote
settings service (a `services.settings` error in the log); the builder's quiet prefs stop it
(§ First-run hygiene). The crash helper also creates `~/Downloads/thunderbird.tmp/`; the builder
sets `MOZ_CRASHREPORTER_DISABLE=1`.

### What pikuri's readers made of the Thunderbird-built profile

The first run of pikuri's code against a Gloda that Thunderbird 159 wrote itself, rather than
our spec fixtures:

- **Works:** `Gloda::Mail#search` (FTS and filter-only), `#read` with the RFC 2047 subject and
  RFC 2231 attachment name decoded (`faktúra_č.12.csv`, part `1.2`), `MessageStore` pulling the
  raw bytes from the POP3 mbox, `Contacts#domains_seen` (the correspondence graph is built from
  the identity and the Sent folder), `Calendar#search` on the `ics`-backed `cache.sqlite`.
- **Gloda writes a literal `undefined` into author and recipient text** —
  `Mira Koskinen <mira@lumo-studio.example> undefined` in `messagesText_content.c3author` /
  `c4recipients` — for every address but the owner's own *as author*: Alex as a recipient gets
  it too (`Alex Novak <alex@novak.example> undefined`, seed build). Probably an address-book field
  for contacts not in the address book. **Decided: the readers strip it**, whatever the real
  profile shows — the model would echo or interpret it, and it costs tokens per address. Match
  only `> undefined` right after an address's closing `>`, so a person named "Undefined"
  survives; the `from:`/`to:` LIKE filters are unaffected. The real-profile check only decides
  the yardoc's wording ("Thunderbird 159 writes…" vs "Gloda writes…"), and it is a count, no
  mail content: `SELECT count(*) FROM messagesText_content WHERE c3author LIKE '%> undefined%'`
  on the owner's host.
- **Gloda drops the `Re:`** from the reply subjects in the FTS text — Thunderbird behaviour,
  worth knowing when a scene searches by subject.
- **A freshly synced calendar event sits in `cache.sqlite-wal`**, invisible to
  `DatabaseSnapshot`'s main-file-only copy until a checkpoint (it showed up after the clean
  quit). The yardoc's "Thunderbird checkpoints aggressively" holds for a busy DB, not for a
  handful of new rows on a running Thunderbird. For the testbed the clean quit fixes it; for a
  live user it is a reader bug, owned by [`thunderbird-wal-snapshot.md`](thunderbird-wal-snapshot.md).
- `DTSTART` without `TZID` came out as `floating` — the demo `.ics` should carry a `TZID`.

## Open questions

None blocking. Two numbers to record when v1 is built: the index time for the full mailbox
(five messages took two seconds; § The build script, step 4), and the `undefined` count on the
owner's real profile (§ What pikuri's readers made of it).
