# frozen_string_literal: true

module Pikuri
  # Gem version, advertised in +pikuri.gemspec+. Bump on every release
  # following semver: patch for bug fixes, minor for backward-compatible
  # additions to the public surface (+Pikuri::Tool+ / +Pikuri::Agent+ /
  # listeners / bundled tools), major for breaking changes to that
  # surface or to the +bin/pikuri-*+ CLIs.
  VERSION = '0.1.0'
end
