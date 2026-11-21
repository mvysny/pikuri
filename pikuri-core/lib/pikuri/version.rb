# frozen_string_literal: true

module Pikuri
  # The one version every pikuri gem ships at, bumped only by
  # <tt>VERSION=x.y.z rake release</tt>. Semver: patch for a bug fix, minor
  # for an addition to the public surface (+Pikuri::Tool+ / +Pikuri::Agent+ /
  # listeners / bundled tools), major for a breaking change to it or to a
  # +bin/pikuri-*+ CLI — except before 1.0, where a breaking change bumps
  # the minor.
  VERSION = '0.2.0'
end
