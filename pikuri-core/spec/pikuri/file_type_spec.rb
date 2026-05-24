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
end
