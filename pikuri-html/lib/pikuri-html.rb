# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-html gem: a per-gem Zeitwerk loader contributing
# +Pikuri::Extractors::HTML+ to the shared +Pikuri::+ namespace, then
# registering it. Unlike pikuri-pdf, requiring is the opt-in: no rival HTML arm
# exists, so there is no host choice to make explicit. The loader constant is
# +HTML_LOADER+ because +Pikuri::Extractors+ is cooperative (pikuri-pdf's
# +PDF_LOADER+ lives there too).
module Pikuri
  module Extractors
    HTML_LOADER = Zeitwerk::Loader.new
    HTML_LOADER.tag = 'pikuri-html'
    HTML_LOADER.push_dir(File.expand_path('.', __dir__))
    HTML_LOADER.ignore(__FILE__)
    HTML_LOADER.inflector.inflect('html' => 'HTML')
    HTML_LOADER.setup
    HTML_LOADER.eager_load

    HTML.register
  end
end
