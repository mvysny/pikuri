# frozen_string_literal: true

require 'json'
require 'openssl'
require 'securerandom'
require 'time'

module Pikuri
  class Tool
    module Search
      # The page text a text-mode search brought back, by handle — what
      # +web_read_cached+ reads. {Engines} stores each row that came with text
      # and prints its handle beside the row; the reader looks the handle up:
      #
      #   handle = PageStore.default.store(url: 'https://example.com/a', title: 'A',
      #                                    text: '…', indexed_at: nil)   # => "a3f9c21e"
      #   PageStore.default.read('a3f9c21e')   # => Page, or nil once evicted
      #
      # Lives in memory only, as long as the Ruby VM ({UrlCache::InMemory}): it
      # holds Brave and Exa output, whose terms forbid storing it — see
      # +D_engine_results_in_memory+. Bounded at {MAX_ENTRIES} pages, least
      # recently used out first, no TTL: the text is the engine's snapshot and a
      # later read makes it no staler. A restart empties it, so old handles then
      # answer "search again".
      #
      # == Handles
      #
      # A handle is the first 8 hex digits of +HMAC-SHA256(secret, url)+, the
      # secret random per process and never written anywhere. Keyed, so a
      # crafted URL can't be made to land on a popular page's handle; derived
      # from the URL, so a stale handle can never come back meaning another
      # page, and the same page keeps its handle across searches. When the
      # 8-digit handle already holds a different URL, the new one takes 12.
      #
      # 8 digits, not fewer: the handle is unguessable only while the space
      # dwarfs the store. Small or sequential handles would let a model in one
      # conversation walk through the pages another conversation in the same
      # process read.
      #
      # Sharing: +P_shared_locked+ — one {.default} for every agent in the
      # process, so a researcher sub-agent's handle reads in its parent too; a
      # +Mutex+ makes the collision check and the write in {#store} one step.
      class PageStore
        # @return [Integer] pages kept, ~100 searches' worth
        MAX_ENTRIES = 1_000

        # @return [Integer] hex digits in a handle
        HANDLE_LENGTH = 8

        # @return [Integer] hex digits in the handle of a URL whose 8-digit one
        #   is taken by another
        LONG_HANDLE_LENGTH = 12

        # A stored page, as {#read} answers it.
        #
        # @!attribute [r] url
        #   @return [String]
        # @!attribute [r] title
        #   @return [String]
        # @!attribute [r] text
        #   @return [String] the full text, as the engine stored it
        # @!attribute [r] indexed_at
        #   @return [Time, nil] when the engine last fetched the page, if known
        Page = Data.define(:url, :title, :text, :indexed_at)

        # @param cache [UrlCache::InMemory, #read, #write] where pages live
        # @param secret [String] HMAC key; random per process by default
        def initialize(cache: UrlCache::InMemory.new(ttl: Float::INFINITY, max_entries: MAX_ENTRIES),
                       secret: SecureRandom.bytes(32))
          @cache = cache
          @secret = secret
          @mutex = Mutex.new
        end

        # The process-wide store {Engines} writes and +web_read_cached+ reads.
        # A method so specs can swap in a fresh one.
        #
        # @return [PageStore]
        def self.default
          DEFAULT
        end

        # Store a page, replacing whatever its URL held.
        #
        # @param url [String]
        # @param title [String]
        # @param text [String]
        # @param indexed_at [Time, nil]
        # @return [String] the page's handle
        def store(url:, title:, text:, indexed_at:)
          entry = JSON.generate('url' => url, 'title' => title, 'text' => text,
                                'indexed_at' => indexed_at&.utc&.iso8601)
          @mutex.synchronize do
            short = digest(url)[0, HANDLE_LENGTH]
            taken = read(short)
            handle = taken.nil? || taken.url == url ? short : digest(url)[0, LONG_HANDLE_LENGTH]
            @cache.write(handle, entry)
            handle
          end
        end

        # @param url [String]
        # @return [String, nil] the handle +url+ is stored under, or +nil+ when
        #   it isn't (never stored, or evicted)
        def handle_for(url)
          full = digest(url)
          [full[0, HANDLE_LENGTH], full[0, LONG_HANDLE_LENGTH]].find { |h| read(h)&.url == url }
        end

        # @param handle [String] as printed in the search results; surrounding
        #   whitespace and brackets are forgiven
        # @return [Page, nil] the page, or +nil+ for an unknown or evicted handle
        def read(handle)
          handle = handle.to_s.strip.delete('[]').downcase
          return nil unless handle.match?(/\A\h{#{HANDLE_LENGTH}}(\h{#{LONG_HANDLE_LENGTH - HANDLE_LENGTH}})?\z/o)

          json = @cache.read(handle)
          return nil if json.nil?

          data = JSON.parse(json)
          Page.new(url: data['url'], title: data['title'], text: data['text'],
                   indexed_at: data['indexed_at'] && Time.iso8601(data['indexed_at']))
        end

        private

        # @param url [String]
        # @return [String] lowercase hex HMAC of +url+
        def digest(url)
          OpenSSL::HMAC.hexdigest('SHA256', @secret, url)
        end

        # The process-wide store; see {.default}.
        #
        # @return [PageStore]
        DEFAULT = new
      end
    end
  end
end
