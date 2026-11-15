# frozen_string_literal: true

module Pikuri
  module Demo
    # Renders a folder of messages as an mbox the way Thunderbird keeps a
    # local folder: a +From - <date>+ separator per message, CRLF line ends,
    # and a body line that starts with +From + escaped as +>From +.
    module Mbox
      # @param messages [Array<Mail::Message>]
      # @return [String] the mbox bytes.
      def self.render(messages)
        messages.sort_by { |m| m.date.to_time }.map do |message|
          raw = message.encoded.gsub(/\r?\n/, "\r\n").gsub(/^(>*From )/, '>\1')
          raw << "\r\n" unless raw.end_with?("\r\n")
          "From - #{message.date.to_time.utc.strftime('%a %b %e %H:%M:%S %Y')}\r\n#{raw}\r\n"
        end.join.b
      end
    end
  end
end
