# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-pdf gem: a per-gem Zeitwerk loader
# contributing +Pikuri::Extractors::PDF+ to the shared +Pikuri::+
# namespace. Defining the module registers *nothing* — a host opts in
# with {Pikuri::Extractors::PDF.register} (see there). The
# +Pikuri::Extractors+ namespace is cooperative (pikuri-extractors adds
# +Documents+/+DOCUMENTS+), so the loader constant is +PDF_LOADER+, not
# +LOADER+, to avoid a collision when both gems load together.
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
