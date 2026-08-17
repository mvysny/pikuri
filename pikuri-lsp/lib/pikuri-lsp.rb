# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-workspace'

# Entry file for the pikuri-lsp gem: mounts a per-gem Zeitwerk loader at this
# +lib/+ (contributing to the shared +Pikuri::+ namespace), so
# +lib/pikuri/lsp/connection.rb+ autoloads as +Pikuri::Lsp::Connection+, etc.
module Pikuri
  # Language Server Protocol client: the questions grep cannot answer — where
  # is this defined, who calls it, what does it inherit from — asked of a real
  # language server and relayed back verbatim. Read-only by construction; the
  # moment it applies an edit it needs the +Confirmer+ seam and stops being a
  # gem you can audit in one sitting.
  #
  # Two layers, and start reading at the first:
  #
  # * {Lsp::Connection} is the *protocol* — JSON-RPC over one IO pair, and
  #   nothing of LSP's vocabulary.
  # * {Lsp::Position} / {Lsp::Range} / {Lsp::Location} / {Lsp::ServerProgress}
  #   are the *boundary* — the wire shapes messy enough that the rest of the gem
  #   should never see them. Coordinates cross it exactly once: 1-based line and
  #   character column inside pikuri, 0-based and {Lsp::PositionEncoding}-encoded
  #   outside.
  module Lsp
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-lsp'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(__FILE__)
    LOADER.setup
    LOADER.eager_load
  end
end
