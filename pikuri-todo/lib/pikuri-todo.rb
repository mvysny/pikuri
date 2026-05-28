# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-todo gem. Sets up a dedicated Zeitwerk
# loader rooted at this gem's +lib/+, contributing to the shared
# +Pikuri::+ namespace alongside pikuri-core. After +require
# 'pikuri-todo'+, +Pikuri::Todo::List+, the four todo tool classes
# (+Create+, +InProgress+, +Completed+, +Delete+), and
# +Pikuri::Todo::Extension+ are all defined.
#
# The loader is per-gem (not shared with pikuri-core's loader) so each
# gem owns its own +lib/+ tree and the cooperation between gems is via
# the Pikuri namespace alone.
module Pikuri
  module Todo
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-todo'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(__FILE__)
    LOADER.setup
    LOADER.eager_load
  end
end
