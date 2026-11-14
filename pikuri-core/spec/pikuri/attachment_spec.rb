# frozen_string_literal: true

RSpec.describe Pikuri::Attachment do
  describe '#to_ruby_llm' do
    # Bytes no sniffer knows, so a ruby_llm left to detect would go by the name.
    it 'states its own MIME type rather than let ruby_llm guess one from the file name' do
      image = Pikuri::Attachment.new(mime: 'image/png', filename: 'notes.txt', bytes: 'opaque'.b)

      raw = image.to_ruby_llm

      assert_equal 'image/png', raw.mime_type
      assert_equal image, Pikuri::Attachment.from_ruby_llm(raw)
    end
  end
end
