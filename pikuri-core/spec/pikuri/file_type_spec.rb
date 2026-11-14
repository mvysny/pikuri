# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::FileType do
  PNG_MAGIC = "\x89PNG\r\n\x1a\n".b
  JPEG_MAGIC = "\xff\xd8\xff\xe0".b
  GIF87_MAGIC = 'GIF87a'.b
  GIF89_MAGIC = 'GIF89a'.b
  WEBP_HEAD = "RIFF\x10\x00\x00\x00WEBP".b
  PDF_MAGIC = '%PDF-1.4'.b

  describe '.detect_mime' do
    it 'recognises PDF by the %PDF- prefix' do
      assert_equal 'application/pdf', described_class.detect_mime(PDF_MAGIC + 'rest of file'.b)
    end

    it 'recognises PNG by its 8-byte signature' do
      assert_equal 'image/png', described_class.detect_mime(PNG_MAGIC + ('x' * 16).b)
    end

    it 'recognises JPEG by its 3-byte SOI+marker prefix' do
      assert_equal 'image/jpeg', described_class.detect_mime(JPEG_MAGIC + ('x' * 16).b)
    end

    it 'recognises GIF87a' do
      assert_equal 'image/gif', described_class.detect_mime(GIF87_MAGIC + ('x' * 16).b)
    end

    it 'recognises GIF89a' do
      assert_equal 'image/gif', described_class.detect_mime(GIF89_MAGIC + ('x' * 16).b)
    end

    it 'recognises WebP via the RIFF...WEBP container marker at offset 8' do
      assert_equal 'image/webp', described_class.detect_mime(WEBP_HEAD + ('x' * 16).b)
    end

    it 'returns nil for plain ASCII text' do
      assert_nil described_class.detect_mime('hello world'.b)
    end

    it 'returns nil for UTF-8 text (no magic match)' do
      assert_nil described_class.detect_mime("héllo wörld".b)
    end

    it 'takes a UTF-8-tagged String too, as a mail part decodes to' do
      assert_nil described_class.detect_mime('héllo wörld')
    end

    it 'returns nil for an opaque-binary blob with no recognised prefix' do
      # Plausible ZIP magic — pikuri does not currently route archives.
      assert_nil described_class.detect_mime("PK\x03\x04".b + ('x' * 16).b)
    end

    it 'returns nil for a short RIFF (no WEBP marker yet)' do
      # RIFF prefix alone is not enough; without the WEBP at offset 8
      # we shouldn't claim image/webp.
      assert_nil described_class.detect_mime('RIFF'.b + ("\x00" * 4).b)
    end

    it 'returns nil for a RIFF container that is not WebP (e.g. WAVE)' do
      wav_head = "RIFF\x10\x00\x00\x00WAVE".b
      assert_nil described_class.detect_mime(wav_head + ('x' * 16).b)
    end

    it 'returns nil for an empty sample' do
      assert_nil described_class.detect_mime(''.b)
    end
  end

  describe '.binary?' do
    it 'flags any NUL byte as binary' do
      assert described_class.binary?("abc\x00def".b)
    end

    it 'flags samples dense in control characters as binary (>30% threshold)' do
      # 50% non-printable: alternating 'a' and a control char 0x01.
      content = (['a', "\x01"] * 200).join.b
      assert described_class.binary?(content)
    end

    it 'accepts plain ASCII text as not-binary' do
      refute described_class.binary?("hello world\n".b)
    end

    it 'accepts UTF-8 text (continuation bytes are not non-printable)' do
      refute described_class.binary?("héllo\nwörld\n".b)
    end

    it 'accepts text with permitted whitespace controls (\\t \\n \\v \\f \\r)' do
      refute described_class.binary?("a\tb\nc\vd\fe\rf".b)
    end

    it 'treats an empty sample as not-binary (empty files take the text path)' do
      refute described_class.binary?(''.b)
    end

    it 'stays under the threshold for a sample at the 30% boundary' do
      # 29% control bytes is below threshold (>30% required).
      content = (['a'] * 71 + ["\x01"] * 29).join.b
      refute described_class.binary?(content)
    end
  end

  describe 'Pathname input' do
    let(:root) { Pathname.new(Dir.mktmpdir('pikuri-file-type-')).realpath }

    after { FileUtils.rm_rf(root) }

    def write(rel, bytes)
      path = root + rel
      File.binwrite(path, bytes)
      path
    end

    it 'detect_mime opens the path and sniffs from the first SAMPLE_BYTES' do
      path = write('shot.png', PNG_MAGIC + ('x' * 16).b)
      assert_equal 'image/png', described_class.detect_mime(path)
    end

    it 'binary? opens the path and applies the heuristic on the sample' do
      path = write('plain.txt', "hello world\n".b)
      refute described_class.binary?(path)

      bin_path = write('opaque.bin', "abc\x00def".b)
      assert described_class.binary?(bin_path)
    end

    it 'reads only up to SAMPLE_BYTES even for a much larger file' do
      # If the implementation slurped the whole file, this test would
      # still pass — but it ensures the cap is correct: only the
      # leading window is consulted, so a giant otherwise-text file
      # with PDF magic in its first bytes is still recognised as PDF.
      tail = 'x' * (Pikuri::FileType::SAMPLE_BYTES * 4)
      path = write('big.pdf', ('%PDF-1.4' + tail).b)
      assert_equal 'application/pdf', described_class.detect_mime(path)
    end

    it 'treats an empty file as not-binary and unrecognised' do
      path = write('empty', ''.b)
      refute described_class.binary?(path)
      assert_nil described_class.detect_mime(path)
    end

    it 'rejects inputs that are neither String nor Pathname with ArgumentError' do
      # Refuse to guess what a stray Integer / Hash / IO means — bytes
      # vs path ambiguity would lurk otherwise.
      assert_raises(ArgumentError) { described_class.detect_mime(42) }
      assert_raises(ArgumentError) { described_class.binary?(42) }
    end
  end

  describe '.read_as_text' do
    let(:root) { Pathname.new(Dir.mktmpdir('pikuri-file-type-rat-')).realpath }

    after { FileUtils.rm_rf(root) }

    def write(rel, bytes)
      path = root + rel
      File.binwrite(path, bytes)
      path
    end

    describe 'plain text' do
      it 'reads a UTF-8 text file as-is' do
        path = write('hello.txt', "Hello, world.\n".b)
        assert_equal "Hello, world.\n", described_class.read_as_text(path)
      end

      it 'reads a Markdown file as-is (no transformation)' do
        path = write('doc.md', "# Heading\n\nParagraph with **bold**.\n".b)
        assert_equal "# Heading\n\nParagraph with **bold**.\n", described_class.read_as_text(path)
      end

      it 'reads an empty file as the empty String' do
        path = write('empty.txt', ''.b)
        assert_equal '', described_class.read_as_text(path)
      end

      it 'reads UTF-8 multi-byte content correctly' do
        path = write('utf8.txt', "héllo wörld\n".b)
        text = described_class.read_as_text(path)
        assert_equal 'UTF-8', text.encoding.name
        assert_includes text, 'héllo wörld'
      end
    end

    describe 'refusals' do
      it 'raises Errno::ENOENT for a missing file' do
        assert_raises(Errno::ENOENT) do
          described_class.read_as_text(root + 'nope.txt')
        end
      end

      it 'raises ArgumentError on a directory' do
        err = assert_raises(ArgumentError) { described_class.read_as_text(root) }
        assert_match(/directory/, err.message)
      end

      it 'raises ArgumentError on a PNG image' do
        path = write('shot.png', PNG_MAGIC + ('x' * 16).b)
        err = assert_raises(ArgumentError) { described_class.read_as_text(path) }
        assert_match(/image/, err.message)
      end

      it 'raises ArgumentError on a JPEG image' do
        path = write('photo.jpg', JPEG_MAGIC + ('x' * 16).b)
        err = assert_raises(ArgumentError) { described_class.read_as_text(path) }
        assert_match(/image/, err.message)
      end

      it 'raises ArgumentError on opaque binary content' do
        # PK\x03\x04 + null bytes → binary by both magic-byte
        # check (no recognised MIME) and binary? heuristic (NUL byte).
        path = write('archive.zip', "PK\x03\x04".b + "\x00" * 32)
        err = assert_raises(ArgumentError) { described_class.read_as_text(path) }
        assert_match(/binary/, err.message)
      end

      it 'raises ArgumentError on a non-Pathname argument' do
        path = write('hello.txt', 'hi'.b)
        err = assert_raises(ArgumentError) { described_class.read_as_text(path.to_s) }
        assert_match(/expected Pathname/, err.message)
      end
    end

    # Shares the write helper defined above. The paged variant
    # returns an Extractor::Page; the LLM-tool callers
    # (Workspace::Read, VectorDb::Tools::Read) own the rendering, so these
    # assert the struct, not formatted strings.
    describe '.read_as_text_paged' do
      describe 'plain text' do
        it 'returns the whole file as a text Page with a known total' do
          path = write('doc.txt', "alpha\nbeta\ngamma\n".b)
          page = described_class.read_as_text_paged(path)

          assert_equal %w[alpha beta gamma], page.lines
          assert_equal 1, page.start_line
          assert_equal 3, page.total_lines
          refute page.more
          refute page.byte_capped
          assert_equal :text, page.kind
        end

        it 'windows by offset and limit, reporting more + total' do
          path = write('long.txt', (1..5).map { |n| "line#{n}" }.join("\n").b)
          page = described_class.read_as_text_paged(path, offset: 2, limit: 2)

          assert_equal %w[line2 line3], page.lines
          assert_equal 2, page.start_line
          assert_equal 5, page.total_lines
          assert page.more
        end

        it 'reports an empty file as zero lines, total 0' do
          path = write('empty.txt', ''.b)
          page = described_class.read_as_text_paged(path)

          assert_empty page.lines
          assert_equal 0, page.total_lines
          refute page.more
        end

        it 'reports an offset past EOF as empty lines with the real total' do
          path = write('short.txt', "one\ntwo\n".b)
          page = described_class.read_as_text_paged(path, offset: 99)

          assert_empty page.lines
          assert_equal 2, page.total_lines
        end

        it 'truncates an over-long line with the marker' do
          path = write('wide.txt', ('x' * (Pikuri::Extractor::PAGE_MAX_LINE_LENGTH + 50)).b)
          page = described_class.read_as_text_paged(path)

          assert page.lines.first.end_with?(Pikuri::Extractor::PAGE_LINE_TRUNCATION_MARKER)
        end

        it 'stops at the byte cap, leaving total_lines nil' do
          line = 'a' * 1023
          path = write('bulky.txt', ((1..80).map { line }.join("\n")).b)
          page = described_class.read_as_text_paged(path)

          assert page.byte_capped
          assert page.more
          assert_nil page.total_lines
        end
      end

      describe 'refusals (same contract as read_as_text)' do
        it 'raises Errno::ENOENT for a missing file' do
          assert_raises(Errno::ENOENT) { described_class.read_as_text_paged(root + 'nope.txt') }
        end

        it 'raises ArgumentError on a directory' do
          err = assert_raises(ArgumentError) { described_class.read_as_text_paged(root) }
          assert_match(/directory/, err.message)
        end

        it 'raises ArgumentError on an image' do
          path = write('shot.png', PNG_MAGIC + ('x' * 16).b)
          err = assert_raises(ArgumentError) { described_class.read_as_text_paged(path) }
          assert_match(/image/, err.message)
        end

        it 'raises ArgumentError on opaque binary content' do
          path = write('archive.zip', "PK\x03\x04".b + "\x00" * 32)
          err = assert_raises(ArgumentError) { described_class.read_as_text_paged(path) }
          assert_match(/binary/, err.message)
        end
      end
    end
  end
end
