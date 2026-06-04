# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-extractors gem. Sets up a dedicated
# Zeitwerk loader rooted at this gem's +lib/+, contributing to the
# shared +Pikuri::+ namespace alongside pikuri-core. After +require
# 'pikuri-extractors'+, +Pikuri::Extractors::Documents+ and the shared
# +Pikuri::Extractors::DOCUMENTS+ instance are defined — but *nothing
# is registered*: extractors plug into +Pikuri::Extractor.registry+
# only when the host script calls their +#register+ explicitly, so a
# +bin/pikuri-*+ picks which extractors it wires in (same opt-in
# philosophy as +c.add_extension+).
#
# The loader is per-gem (not shared with pikuri-core's loader) so each
# gem owns its own +lib/+ tree and the cooperation between gems is via
# the Pikuri namespace alone.
module Pikuri
  module Extractors
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-extractors'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(__FILE__)
    LOADER.setup
    LOADER.eager_load
  end
end
