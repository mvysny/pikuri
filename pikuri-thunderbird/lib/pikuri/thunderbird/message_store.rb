# frozen_string_literal: true

require 'json'
require 'uri'

module Pikuri
  module Thunderbird
    # Finds one message's raw RFC 822 bytes in Thunderbird's offline store: an
    # mbox file per folder, under +ImapMail/<server>/+ (IMAP) or +Mail/+ (local
    # folders). Gloda has every message's decoded text but never its bytes, so
    # an attachment can only be read from here:
    #
    #   store = MessageStore.new(profile: profile)
    #   rec   = gloda_mail.read(message_id: id)
    #   store.raw_message(message_id: rec[:message_id], folder_uris: rec[:folder_uris])
    #   # => "Received: …\r\nMessage-ID: <…>\r\n…" (binary), or nil if no copy is stored
    #
    # +nil+ is the "not stored on this computer" answer: a copy gone from the
    # offline store since Gloda indexed it. A message whose body was never
    # offline doesn't get here: Gloda indexed it from its headers alone, with
    # no attachments to ask for. This class never fetches a message over IMAP.
    #
    # == Implementation details
    #
    # A folder URI maps to its mbox through +prefs.js+, the only file naming
    # which account owns which store directory (a second account on one host
    # gets +imap.gmail-1.com+). Gloda's folder URIs are not valid RFC 3986 —
    # raw +[Gmail]+ brackets and spaces — so they are split by regex. A folder
    # name is mapped verbatim: one with characters the filesystem can't hold,
    # which Thunderbird hashes into its file name (+NS_MsgHashIfNecessary+),
    # isn't found, and its messages answer "not stored". Unhandled until a
    # real folder hits it.
    #
    # Within the mbox the message is found by a linear scan for its
    # +Message-ID:+ header (~0.5 s for a 440 MB +[Gmail]/All Mail+), skipping
    # copies whose +X-Mozilla-Status+ carries the expunged bit. Gloda's
    # +messageKey+ is not used: it is the IMAP UID under +ImapMail/+, and the
    # byte offset is only in the +.msf+ Mork summary.
    #
    # The scan reads the live file, with no snapshot: Thunderbird appends new
    # mail and compacts by renaming a new file over the old one, so the one fd
    # held for the whole scan stays self-consistent.
    #
    # Sharing: +P_stateless+ — every call reads +prefs.js+ and the mbox afresh.
    class MessageStore
      # Raised when a folder can't be mapped to a readable mbox, or the message
      # is too large to open. The message is LLM-presentable.
      Error = Class.new(StandardError)

      # @return [Integer] largest raw message read into memory. A 25 MB
      #   attachment (a typical provider's limit) is ~34 MB as base64.
      MAX_MESSAGE_BYTES = 40 * 1024 * 1024

      # @return [Integer] scan read size.
      CHUNK = 8 * 1024 * 1024

      # @return [Integer] bytes kept from the previous chunk, so the separator
      #   above a +Message-ID:+ near a chunk start is still in the buffer.
      #   Bounds the header length the scan handles.
      OVERLAP = 256 * 1024

      # @return [Integer] +X-Mozilla-Status+'s deleted-but-not-compacted bit.
      EXPUNGED = 0x0008

      # @param profile [Profile] the Thunderbird profile whose store to read.
      # @return [MessageStore]
      def initialize(profile:)
        @profile = profile
      end

      # The first live copy of +message_id+ in any of +folder_uris+, in order.
      #
      # @param message_id [String] the RFC +Message-ID+, without angle brackets
      #   (as Gloda stores it).
      # @param folder_uris [Array<String>] Gloda +folderURI+s to try.
      # @return [String, nil] the raw message (binary, CRLF, without the mbox
      #   +From - + separator line), or +nil+ when no folder holds a copy.
      # @raise [Error] when a folder's account isn't in +prefs.js+, its store
      #   is not mbox, or the message exceeds {MAX_MESSAGE_BYTES}.
      def raw_message(message_id:, folder_uris:)
        servers = read_servers
        folder_uris.each do |uri|
          path = mbox_path(servers, uri)
          next unless File.file?(path)

          raw = scan(path, message_id)
          return raw if raw
        end
        nil
      end

      private

      # @return [Hash{Array(String, String, String) => Hash{String => Object}}]
      #   +[scheme, userName, hostname]+ → that server's +mail.server.serverN.*+
      #   prefs; the scheme is +imap+ for IMAP and +mailbox+ for local stores.
      def read_servers
        prefs = Hash.new { |h, k| h[k] = {} }
        File.foreach(@profile.prefs_path, encoding: 'UTF-8') do |line|
          m = line.match(/\Auser_pref\("mail\.server\.(server\d+)\.([^"]+)",\s*(.*)\);\s*\z/) or next
          prefs[m[1]][m[2]] = JSON.parse(m[3])
        end
        prefs.each_value.to_h do |s|
          [[s['type'] == 'imap' ? 'imap' : 'mailbox', s['userName'], s['hostname']], s]
        end
      end

      # @param servers [Hash] from {#read_servers}.
      # @param uri [String] a Gloda +folderURI+, e.g.
      #   +"imap://me%40gmail.com@imap.gmail.com/[Gmail]/All Mail"+.
      # @return [String] the folder's mbox path: +a/b/c+ → +<dir>/a.sbd/b.sbd/c+.
      # @raise [Error] when no account owns the URI or its store isn't mbox.
      def mbox_path(servers, uri)
        m = uri.match(%r{\A(\w+)://([^@/]+)@([^/]+)/(.+)\z}) or
          raise Error, "unrecognised Thunderbird folder #{uri.inspect}."
        scheme, user, host, path = m.captures.map { URI.decode_uri_component(_1) }
        server = servers[[scheme, user, host]] or
          raise Error, "no account in Thunderbird's prefs.js owns the folder #{uri.inspect}."
        store = server['storeContractID']
        if store && !store.end_with?('/berkeleystore;1')
          raise Error, "the account behind #{uri.inspect} stores mail as #{store}, which pikuri can't read (only mbox)."
        end

        dir = server['directory-rel']&.sub('[ProfD]', "#{@profile.dir}/") || server['directory'] or
          raise Error, "Thunderbird's prefs.js names no store directory for the folder #{uri.inspect}."
        *parents, leaf = path.split('/')
        File.join(dir, *parents.map { "#{_1}.sbd" }, leaf)
      end

      # @param path [String] an mbox file.
      # @param message_id [String]
      # @return [String, nil] the first live copy's raw bytes.
      def scan(path, message_id)
        needle = Regexp.new("^Message-ID:[ \\t]*(?:\\r?\\n[ \\t]+)?<#{Regexp.escape(message_id.b)}>".b,
                            Regexp::IGNORECASE)
        File.open(path, 'rb') do |f|
          buf = +''.b
          base = 0 # file offset of buf's first byte
          from = 0 # buf index the next match search starts at
          loop do
            chunk = f.read(CHUNK)
            buf << chunk if chunk
            while (m = needle.match(buf, from))
              from = m.end(0)
              start = buf.rindex(/^From - /, m.begin(0)) or next
              # A blank line between separator and match puts the match in a
              # body: a forwarded mail quoting its own Message-ID header.
              next if buf.byteslice(start, m.begin(0) - start).match?(/\r?\n\r?\n/)

              raw = message_at(f, base + start)
              return raw unless expunged?(raw)
            end
            return nil unless chunk

            drop = buf.bytesize - OVERLAP
            next unless drop.positive?

            buf = buf.byteslice(drop..)
            base += drop
            from = [from - drop, 0].max
          end
        end
      end

      # Reads with +pread+, so the scan's own file position is untouched should
      # this copy turn out expunged.
      #
      # @param f [File] the open mbox.
      # @param offset [Integer] where the message's +From - + line starts.
      # @return [String] the message, without that line, up to the next one.
      # @raise [Error] past {MAX_MESSAGE_BYTES}.
      def message_at(f, offset)
        out = +''.b
        loop do
          chunk = begin
            f.pread(CHUNK, offset + out.bytesize)
          rescue EOFError
            break
          end
          searched = [out.bytesize - 8, 1].max
          out << chunk
          if (i = out.index("\nFrom - ", searched))
            out = out.byteslice(0, i + 1)
            break
          end
          if out.bytesize > MAX_MESSAGE_BYTES
            raise Error, "this message is over #{MAX_MESSAGE_BYTES / (1024 * 1024)} MB, too large to open here."
          end
        end
        out.byteslice((out.index("\n") || out.bytesize) + 1..) || +''.b
      end

      # @param raw [String] one message.
      # @return [Boolean] whether Thunderbird marked it deleted but has not
      #   compacted it away yet.
      def expunged?(raw)
        header = raw[/\A.*?\r?\n\r?\n/m] || raw
        status = header[/^X-Mozilla-Status:[ \t]*(\h+)/i, 1]
        !status.nil? && status.hex.anybits?(EXPUNGED)
      end
    end
  end
end
