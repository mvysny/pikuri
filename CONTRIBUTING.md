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

Pikuri's seven gems release in lockstep: every release bumps a
single shared `Pikuri::VERSION` constant
(`pikuri-core/lib/pikuri/version.rb`) which every per-gem gemspec
reads, then builds and pushes each gem to rubygems.org in
dependency order. The metagem `pikuri` releases last so its
dependency declarations pin the just-published sibling versions.

Pre-flight:

- Working tree must be clean (`git status` shows nothing
  uncommitted).
- You must be logged into rubygems.org as a pusher for every
  `pikuri-*` gem (`gem signin`).
- `bundle exec rake test` is green across the whole monorepo.

Release:

```sh
VERSION=x.y.z bundle exec rake release
```

What `rake release` does:

1. Rewrites `pikuri-core/lib/pikuri/version.rb` with the new
   version (single source of truth read by every gemspec).
2. Commits the bump as `vx.y.z`.
3. In each gem directory, `gem build *.gemspec` to produce a
   `.gem` file, then `gem push` it to rubygems.org. Order:
   `pikuri-core` → `pikuri-skills` → `pikuri-mcp` →
   `pikuri-workspace` → `pikuri-code` → `pikuri-assistant` →
   `pikuri`.
4. `git tag vx.y.z` on the bump commit.

Afterwards, push the commit and tag:

```sh
git push && git push --tags
```

If `gem push` fails partway through the fan-out (e.g. network
blip), the already-pushed gems are public on rubygems.org and
cannot be un-pushed cleanly — yanking is the only recourse, and
yanked versions still occupy the version number. Re-running
`rake release` with the same `VERSION` will fail at the bump
step (working tree dirty, or the version commit already exists);
recover by bumping to the next patch version and releasing that.
