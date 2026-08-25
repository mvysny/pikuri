# Contributing to pikuri

## Tests

```sh
bundle exec rake test
```

`rake test` fans out `rspec` across every gem in the monorepo
(`pikuri-core/spec/`, `pikuri-skills/spec/`, etc.) — same shape
Rails (rails/rails) uses for its multi-gem monorepo. To run a
single gem's specs in isolation:

```sh
cd pikuri-core && bundle exec rspec
```

## Releasing

Every gem in the monorepo releases in lockstep: one shared
`Pikuri::VERSION` constant (`pikuri-core/lib/pikuri/version.rb`),
which every per-gem gemspec reads, is bumped once and every gem is
built and pushed at that version. The `Rakefile`'s `GEMS` list is
the authority on which gems those are — it is kept in dependency
order because that documents the graph, but rubygems.org does not
enforce push order, so the fan-out ignores it.

Pre-flight:

- `bundle exec rake test` is green across the whole monorepo.
- Working tree clean (a version bump left by an earlier failed run
  is tolerated).
- You are signed in to rubygems.org as a pusher for the `pikuri-*`
  gems (`gem signin`).

Rehearse first — a release is irreversible, since a pushed gem can
be yanked but its version number is spent forever:

```sh
DRY_RUN=1 VERSION=x.y.z bundle exec rake release
```

The rehearsal runs the pre-flight, the bump, the builds, the OTP
window wait and the prompt for real, reports what it *would* commit,
push and tag, and reverts the bump on the way out.

Release:

```sh
VERSION=x.y.z bundle exec rake release
```

What it does, in order — the ordering is the point, so that a single
OTP code covers every push:

1. **Pre-flight** each gem against rubygems.org. A version already
   published is reported and skipped; a gem name owned by someone
   else refuses the release outright.
2. **Bump** `Pikuri::VERSION`.
3. **Build** every gem, so a gemspec error surfaces before anything
   is public.
4. **Commit** the bump as `vx.y.z`, carrying `Gemfile.lock` (bundler
   rewrites it whenever the constant changes).
5. **Wait** for the top of the next TOTP window, announcing it — that
   pause is your cue to fetch your authenticator.
6. **Ask** for one OTP code on stdin.
7. **Push** two gems at a time, spending that one code.
8. **Report** every gem as pushed / skipped / failed, and **tag**
   `vx.y.z` if nothing failed.

Afterwards, push the commit and tag:

```sh
git push && git push --tags
```

**If something fails partway, just run it again.** Every step is
idempotent: gems that already landed are skipped and reported, and an
applied bump, an existing commit and an existing tag are passed over.
An expired OTP code costs a re-run, not a version number. This is why
the task never re-prompts mid-push — retry is the recovery.

Why one code covers sixteen pushes, and why it is typed rather than
passed in the environment: `DECISIONS.md` `D-release-one-otp`.
