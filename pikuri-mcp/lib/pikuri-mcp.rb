# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-mcp gem. Sets up a dedicated Zeitwerk
# loader rooted at this gem's +lib/+, contributing to the shared
# +Pikuri::+ namespace alongside pikuri-core. After
# +require 'pikuri-mcp'+, +Pikuri::Mcp::Registry+,
# +Pikuri::Mcp::Servers+, +Pikuri::Mcp::Synthesizer+,
# +Pikuri::Mcp::Verifier+, +Pikuri::Mcp::Cache+,
# +Pikuri::Mcp::ClientWrapper+ and +Pikuri::Mcp::Extension+ are all
# defined.
#
# Per-gem loader (not shared with pikuri-core's loader) so each gem
# owns its own +lib/+ tree and the cooperation between gems is via
# the +Pikuri+ namespace alone. See pikuri-core/lib/pikuri-core.rb
# for the core loader.
#
# The gem's +prompts/+ directory is appended to +Pikuri::PROMPT_DIRS+
# so +Pikuri.prompt(:'pikuri-openlibrary')+ (the bin/pikuri-openlibrary
# demo's system prompt) resolves regardless of which gem shipped the
# file.
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)

module Pikuri
  module Mcp
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-mcp'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(__FILE__)
    LOADER.setup
    LOADER.eager_load
  end
end
