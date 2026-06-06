# frozen_string_literal: true

require 'digest'
require 'json'

module Pikuri
  module Mcp
    # On-disk cache for the per-server descriptions
    # {Servers#try_synthesize_description} pays an LLM round-trip to
    # produce. Wraps {Pikuri::UrlCache} for storage; this class owns
    # the *key calculation* — the fingerprint of every input that
    # could change the synthesized output, so an unchanged surface
    # short-circuits to the stored description and a changed surface
    # auto-invalidates.
    #
    # == What goes into the key
    #
    # The key hashes a canonical JSON serialization of:
    #
    # * +model_id+ — synthesis quality varies by model; cached output
    #   from a different model should not be served.
    # * +prompt_version+ — {Servers::PROMPT_VERSION}. Bumped when the
    #   synthesizer prompt changes meaningfully so old cache entries
    #   stop being served without having to delete the cache file.
    # * Transport descriptor — for {Registry::StdioEntry}, the argv;
    #   for {Registry::HttpEntry}, the URL.
    # * Server name + version from +client.server_info['serverInfo']+.
    # * Full tools surface: every tool's +name+, +description+, and
    #   +input_schema+ — including nested property names, types, and
    #   per-property descriptions. The surface is canonicalised
    #   (recursive sort) so a server that reorders its tools array
    #   or its schema keys doesn't blow the cache.
    #
    # The server's id from the registry is intentionally *not* part of
    # the key — renaming a server entry in the registry doesn't change
    # what the server actually does, and the id appears only as a
    # passing reference in the synth prompt, never in the produced
    # description.
    #
    # == Storage
    #
    # Reuses {Pikuri::UrlCache} with a +ttl: Float::INFINITY+. There is
    # no time-based expiry — cache entries are valid forever, until
    # the keyed surface changes. To force a rebuild of everything, +rm+
    # the {DIR} directory (or bump {Servers::PROMPT_VERSION}).
    #
    # == Fail-soft contract
    #
    # {#fetch} mirrors {UrlCache#fetch} — yields on miss, returns the
    # block's result, and persists it. {Servers} additionally rescues
    # +StandardError+ around the {#fetch} call to keep startup robust
    # against a corrupt cache file or a writer-side error.
    class Cache
      # Bumping {Servers::PROMPT_VERSION} invalidates every cached
      # entry; this class doesn't define one of its own.

      # On-disk root. Sibling of {Pikuri::UrlCache::ROOT_DIR} so all
      # of pikuri's caches live under one path.
      DIR = File.join(File.dirname(UrlCache::ROOT_DIR), 'mcp_descriptions').freeze

      # @param model_id [String, nil] the synthesizer model id; folded
      #   into the cache key so a model swap doesn't serve stale output
      # @param prompt_version [Integer] {Servers::PROMPT_VERSION}; folded
      #   into the key so a prompt edit invalidates the world
      # @param dir [String] storage directory; defaults to {DIR}
      def initialize(model_id:, prompt_version:, dir: DIR)
        @model_id = model_id
        @prompt_version = prompt_version
        @url_cache = UrlCache.new(ttl: Float::INFINITY, dir: dir)
      end

      # Return the cached description for the given +(entry, client,
      # tools)+ triple if a fresh entry exists, otherwise yield to
      # compute it (typically a one-shot thinker-agent run inside
      # {Servers#try_synthesize_description}), persist the result, and
      # return it.
      #
      # @param entry [Registry::StdioEntry, Registry::HttpEntry]
      # @param client [MCP::Client] for +server_info+ (name + version)
      # @param tools [Array<MCP::Client::Tool>] the server's tool list
      # @yieldreturn [String] freshly-computed description
      # @return [String] cached or freshly-computed description
      def fetch(entry:, client:, tools:, &block)
        @url_cache.fetch(key_for(entry, client, tools), &block)
      end

      # Compute the canonical fingerprint string for a +(entry, client,
      # tools)+ triple. The fingerprint is what {Pikuri::UrlCache}
      # SHA-256s into the on-disk filename; we don't hash here so the
      # raw JSON is inspectable in tests.
      #
      # @return [String] canonical JSON over the keyed inputs
      def key_for(entry, client, tools)
        info = (client.server_info || {})['serverInfo'] || {}
        fingerprint = {
          'model_id' => @model_id,
          'prompt_version' => @prompt_version,
          'transport' => transport_descriptor(entry),
          'server_name' => info['name'],
          'server_version' => info['version'],
          'tools' => tools_descriptor(tools)
        }
        JSON.generate(canonicalize(fingerprint))
      end

      private

      def transport_descriptor(entry)
        case entry
        when Registry::StdioEntry then { 'kind' => 'stdio', 'command' => entry.command }
        when Registry::HttpEntry  then { 'kind' => 'http',  'url' => entry.url }
        else                           { 'kind' => 'unknown', 'class' => entry.class.to_s }
        end
      end

      def tools_descriptor(tools)
        tools.map do |t|
          {
            'name' => t.name,
            'description' => t.description,
            'input_schema' => t.input_schema || {}
          }
        end
      end

      # Recursively normalize a Hash/Array tree so semantically-equal
      # inputs produce byte-identical JSON: Hash keys sorted, String
      # vs Symbol keys both stringified, Arrays left in order (order
      # is part of the meaning in JSON Schema's +required+).
      def canonicalize(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(k, v), out| out[k.to_s] = canonicalize(v) }
             .sort.to_h
        when Array
          obj.map { |v| canonicalize(v) }
        else
          obj
        end
      end

      # Null cache: drop-in replacement that always misses and never
      # persists. {Servers} uses this as the default when no real cache
      # is provided, so the body of +#try_synthesize_description+ can
      # call +@cache.fetch(...)+ unconditionally instead of branching
      # on +nil+. Same shape as {Pikuri::UrlCache::NULL}.
      NULL = Object.new
      def NULL.fetch(entry:, client:, tools:)
        yield
      end
      NULL.freeze
    end
  end
end
