# frozen_string_literal: true

require_relative '../pikuri-core/lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-thunderbird'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Local Thunderbird mail + calendar tools for pikuri.'
  spec.description = <<~DESC
    pikuri-thunderbird lets a pikuri agent search and read the user's
    *local* Thunderbird data — mail folders and cached calendars — by
    reading Thunderbird's own on-disk profile. It never speaks
    IMAP/POP3/SMTP itself and never egresses: search and read are both
    inbound-only, so the demo (+bin/pikuri-thunderbird+) breaks the
    lethal trifecta by construction, exactly like +bin/pikuri-corpus+.

    Mail search rides Thunderbird's Gloda index
    (+global-messages-db.sqlite+) as a pre-decoded corpus: pikuri copies a
    consistent snapshot, builds its own ephemeral FTS5 index over the
    decoded columns, and serves ranked search + full-body reads with no
    MIME parsing. Calendar reads come from the +calendar-data/*.sqlite+
    stores (normalized columns, no ICS parser for the common case).

    Any *outbound* action (compose a mail, create an event) is opt-in and
    always a human-gated hand-off to Thunderbird's own UI —
    pikuri writes nothing to Thunderbird's stores and sends nothing itself.
    See +pikuri-thunderbird/design/architecture.md+.
  DESC

  spec.homepage = 'https://codeberg.org/mvysny/pikuri'
  spec.license  = 'MIT'

  spec.required_ruby_version = '>= 3.3'

  spec.metadata = {
    'source_code_uri'       => "#{spec.homepage}/src/branch/master",
    'changelog_uri'         => "#{spec.homepage}/src/branch/master/CHANGELOG.md",
    'bug_tracker_uri'       => "#{spec.homepage}/issues",
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir[
    'lib/**/*.rb',
    'prompts/*.txt',
    'LICENSE',
    'README.md',
    'design/architecture.md'
  ]
  spec.require_paths = ['lib']

  # Agent runtime + Tool base class + Extension protocol + the Subprocess
  # chokepoint (used for the reflink snapshot copy) + Finalizers (snapshot
  # reaping) all live in pikuri-core. Lockstep-versioned.
  spec.add_dependency 'pikuri-core', "= #{Pikuri::VERSION}"

  # Gloda + the calendar stores are SQLite; we read them via the sqlite3
  # gem (SQLite 3.53.2 ships FTS5, which the ephemeral mail index needs).
  # We only ever open the plain tables + build our own FTS5 — never
  # Gloda's mozporter-tokenized fts3 vtable, which the gem cannot resolve.
  spec.add_dependency 'sqlite3', '~> 2.9'

  # Parse-only MIME, to walk a stored message to one attachment part. Never
  # used to send: `require 'mail'` loads Net::SMTP, but nothing here calls
  # Mail#deliver or delivery_method.
  spec.add_dependency 'mail', '~> 2.9'

  # Expands a recurring event's RRULE into its dates within a search window.
  # 0.17.0 audited: no network, IPC, eval or file writes; it has no loop
  # guard of its own, so Recurrence bounds frequency, COUNT and the window.
  spec.add_dependency 'ice_cube', '~> 0.17'

  # The event's Olson zone, so a 10:00 Helsinki weekly stays 10:00 across
  # DST. Reads the system's /usr/share/zoneinfo; no tzinfo-data needed.
  spec.add_dependency 'tzinfo', '~> 2.0'
end
