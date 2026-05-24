# frozen_string_literal: true

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
end
