# frozen_string_literal: true

module Pikuri
  module Thunderbird
    class Gloda
      # One attachment as Gloda indexed it: the +attachmentInfos+ attribute,
      # which Gloda stores in +messages.jsonAttributes+ as positional arrays:
      #
      #   ["invoice.pdf", "application/pdf", 1357206, "1.2", null, false]
      #    name           content_type       size     part   url   external
      #
      # Gloda's values beat the message's own headers: +name+ is already
      # RFC 2231 / encoded-word decoded, and +content_type+ is sniffed from the
      # file name where the part says +application/octet-stream+.
      #
      # * +name+ — +String+, sender-authored.
      # * +content_type+ — +String+, lowercased.
      # * +size+ — +Integer+ decoded bytes, but +-1+ when unknown and +0+ for
      #   every +message/rfc822+ part; display it, never enforce it.
      # * +part+ — +String+ MIME part number, Thunderbird numbering: root +"1"+,
      #   children +"1.1"+, +"1.2"+, …
      # * +external+ — +Boolean+, the bytes live at a remote URL, not in the
      #   message.
      Attachment = Data.define(:name, :content_type, :size, :part, :external) do
        # @param entry [Array] one +attachmentInfos+ element.
        # @return [Attachment]
        # @raise [NoMatchingPatternError] on a shape Gloda never wrote.
        def self.from_gloda(entry)
          entry => [String => name, String => content_type, Integer => size, String => part, _url, external]
          new(name:, content_type: content_type.downcase, size:, part:, external: external == true)
        end
      end
    end
  end
end
