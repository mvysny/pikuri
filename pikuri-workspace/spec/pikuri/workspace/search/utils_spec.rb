# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Workspace::Search::Utils do
  describe '.oversized_root_refusal' do
    # Point $HOME at a controlled tree so the refusal's listing is assertable
    # (Dir.home reads $HOME on Linux). realpath the temp dir up front so it
    # matches the normalized root the guard compares against.
    around do |example|
      Dir.mktmpdir('pikuri-fake-home-') do |dir|
        @home = Pathname.new(dir).realpath
        FileUtils.mkdir_p(@home + 'work')
        FileUtils.mkdir_p(@home + '.config')
        File.write(@home + 'todo.txt', 'x')
        File.write(@home + '.bashrc', 'x')

        old = ENV.fetch('HOME', nil)
        ENV['HOME'] = @home.to_s
        begin
          example.run
        ensure
          ENV['HOME'] = old
        end
      end
    end

    it 'returns nil for an ordinary subdirectory' do
      assert_nil described_class.oversized_root_refusal(@home + 'work', verb: 'search')
    end

    it 'refuses the whole home dir and lists its immediate entries' do
      result = described_class.oversized_root_refusal(@home, verb: 'search')

      assert result.start_with?('Error: refusing to search from'), result[0, 80].inspect
      assert_includes result, 'the whole home directory'
      assert_includes result, 'too broad'
      # dotfiles included (ls -a), directories flagged with a trailing slash.
      %W[.config/ work/ .bashrc todo.txt].each { |e| assert_includes result, e }
    end

    it 'lists directories (slash-suffixed) before files, each group sorted' do
      result = described_class.oversized_root_refusal(@home, verb: 'list')
      listing = result.split(":\n", 2).last

      assert_equal ".config/  [empty]\nwork/  [empty]\n.bashrc  1B\ntodo.txt  1B", listing
    end

    it 'threads the verb into the message' do
      assert_includes described_class.oversized_root_refusal(@home, verb: 'list'),
                      'refusing to list from'
    end

    it 'refuses the filesystem root' do
      result = described_class.oversized_root_refusal(Pathname.new('/'), verb: 'search')

      assert result.start_with?('Error: refusing to search from /'), result[0, 80].inspect
      assert_includes result, 'the whole filesystem root'
    end

    it 'refuses a parent of home (broader than home itself) and lists it' do
      parent = @home.parent
      result = described_class.oversized_root_refusal(parent, verb: 'search')

      assert result.start_with?("Error: refusing to search from #{parent}"), result[0, 120].inspect
      assert_includes result, 'a parent of your home directory'
      assert_includes result, 'too broad'
      # non-dead-ending: hands back the parent's children so the model can
      # pick the actual home dir and retry.
      assert_includes result, "#{@home.basename}/"
    end
  end

  describe '.head_truncate' do
    it 'passes short input through with no marker' do
      assert_equal ["a\nb", ''], described_class.head_truncate("a\nb", max_bytes: 100, hint: 'x')
    end

    it 'cuts at the last newline and threads the hint into the marker' do
      raw = (['0123456789'] * 10).join("\n")

      content, marker = described_class.head_truncate(raw, max_bytes: 25, hint: 'narrow it')

      assert_equal "0123456789\n0123456789", content
      assert_includes marker, 'bytes omitted'
      assert_includes marker, 'narrow it'
    end
  end
end
