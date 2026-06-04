# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-pdf gem. Sets up a dedicated Zeitwerk
# loader rooted at this gem's +lib/+, contributing to the shared
# +Pikuri::+ namespace alongside pikuri-core. After +require
# 'pikuri-pdf'+, +Pikuri::Extractors::PDF+ is defined — but *nothing
# is registered*: extractors plug into +Pikuri::Extractor.registry+
# only when the host script calls their +register+ explicitly, so a
# +bin/pikuri-*+ picks which extractors it wires in (same opt-in
# philosophy as +c.add_extension+, same shape as pikuri-extractors'
# +DOCUMENTS.register+).
#
# The +Pikuri::Extractors+ namespace is cooperative: pikuri-extractors
# contributes +Documents+ / +DOCUMENTS+, this gem contributes +PDF+.
# Each gem's loader manages only its own files; the loader constant is
# +PDF_LOADER+ (not +LOADER+) so both gems can be loaded together
# without colliding in the shared namespace.
module Pikuri
  module Extractors
    PDF_LOADER = Zeitwerk::Loader.new
    PDF_LOADER.tag = 'pikuri-pdf'
    PDF_LOADER.push_dir(File.expand_path('.', __dir__))
    PDF_LOADER.ignore(__FILE__)
    PDF_LOADER.inflector.inflect('pdf' => 'PDF')
    PDF_LOADER.setup
    PDF_LOADER.eager_load
  end
end
