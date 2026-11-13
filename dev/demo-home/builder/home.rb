# frozen_string_literal: true

require 'fileutils'

module Pikuri
  module Demo
    # The demo +~/Documents+, the secretary's default, and the guard that
    # keeps the build away from anyone's real files.
    #
    # The demo home is for pikuri's developers, on a machine whose
    # +~/Documents+ holds nothing of its own (the dev VM). The directory
    # carries a marker file, {MARKER}; the build refuses while it is non-empty
    # and unmarked, and never deletes an unmarked directory.
    class Home
      # The marker every demo directory carries, here and in the Thunderbird
      # testbed's profile.
      MARKER = '.pikuri-demo'

      # Raised when the guard finds something that isn't a demo.
      class Refused < StandardError; end

      # @return [String] absolute demo documents directory.
      attr_reader :documents_dir

      def initialize
        @documents_dir = File.expand_path('~/Documents')
      end

      # @param dir [String]
      # @return [Boolean] whether +dir+ carries {MARKER}.
      def self.marked?(dir) = File.file?(File.join(dir, MARKER))

      # Raises before anything is written.
      #
      # @return [void]
      # @raise [Refused] when +~/Documents+ is non-empty and unmarked.
      def guard!
        return if !File.exist?(@documents_dir) || self.class.marked?(@documents_dir) || Dir.empty?(@documents_dir)

        raise Refused, "#{@documents_dir} is not a pikuri demo (no #{MARKER}) and not empty. " \
                       'The demo build never overwrites it; move it aside.'
      end

      # Wipes a previous demo and writes the documents afresh, marked. Call
      # after {#guard!}.
      #
      # @param documents [Documents]
      # @return [void]
      def write!(documents)
        FileUtils.rm_rf(@documents_dir) if self.class.marked?(@documents_dir)
        FileUtils.mkdir_p(@documents_dir, mode: 0o700)
        File.write(File.join(@documents_dir, MARKER), "A pikuri demo. Holds no real files.\n")
        documents.write(@documents_dir)
      end
    end
  end
end
