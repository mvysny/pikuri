# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-subagents gem. After
# +require 'pikuri-subagents'+:
#
# * +Pikuri::Tool::SubAgent::RESEARCHER+ is defined (bundled persona;
#   network-read tools only).
# * +pikuri-subagents/prompts/+ is appended to +Pikuri::PROMPT_DIRS+
#   so +Pikuri.prompt(:'persona-researcher')+ resolves to the right
#   file regardless of which gem actually shipped it.
#
# The gem ships a single Ruby file (the persona constant), so we skip
# Zeitwerk entirely and load it with +require_relative+. If a future
# release adds enough files to justify autoloading, that's the moment
# to flip to a Zeitwerk loader rooted under +Pikuri::Tool::SubAgent+
# via +push_dir(..., namespace: ...)+ — see CLAUDE.md §Conventions on
# nesting under +Pikuri::Tool+.
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)

require_relative 'pikuri/tool/sub_agent/researcher'
