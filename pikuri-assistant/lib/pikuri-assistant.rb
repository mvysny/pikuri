# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-skills'
require 'pikuri-mcp'

# Entry file for the pikuri-assistant gem. The gem itself has no
# Ruby library code — it ships only the +bin/pikuri-assistant+
# binary + the +prompts/pikuri-assistant.txt+ system prompt — but
# the entry file registers the prompts directory on
# +Pikuri::PROMPT_DIRS+ so +Pikuri.prompt(:'pikuri-assistant')+
# resolves after this gem loads. Same multi-gem prompt-dir pattern
# pikuri-code uses.
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)
