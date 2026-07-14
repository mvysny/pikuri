# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-thunderbird gem: local Thunderbird mail +
# calendar search/read for a pikuri agent, home of the
# +bin/pikuri-thunderbird+ no-egress demo. {Pikuri::Thunderbird::Extension}
# is the one-call wiring; it reads Thunderbird's own on-disk profile
# ({Pikuri::Thunderbird::Profile} discovers it) and never touches the
# network.
#
# The load-bearing posture (v1): search + read are inbound-only, so an
# agent wired with only these tools has private data + untrusted content
# but *no egress leg* — the lethal trifecta is broken by construction, the
# same model as +bin/pikuri-corpus+. Outbound actions (compose / create
# event) are v2 and are always human-gated hand-offs to Thunderbird's own
# UI. Threat model: +DESIGN.md+; design rationale: +ideas/thunderbird.md+.
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)

module Pikuri
  module Thunderbird
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-thunderbird'
    LOADER.push_dir(__dir__)
    LOADER.ignore(File.expand_path('pikuri-thunderbird.rb', __dir__))
    LOADER.setup
    LOADER.eager_load
  end
end
