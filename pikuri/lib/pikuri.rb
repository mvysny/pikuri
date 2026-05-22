# frozen_string_literal: true

# +pikuri+ metagem entry file. Boots every sibling gem in dependency
# order so +require 'pikuri'+ pulls in the whole pikuri-* family in
# one shot. Each sibling owns its own Zeitwerk loader + PROMPT_DIRS
# registration; we just need them loaded.
#
# Privacy-conscious users who want a minimal dependency tree should
# install +pikuri-core+ directly and skip this metagem.
require 'pikuri-core'
require 'pikuri-skills'
require 'pikuri-workspace'
require 'pikuri-mcp'
require 'pikuri-code'
require 'pikuri-assistant'
