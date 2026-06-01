# frozen_string_literal: true

require 'faraday'
require 'json'

module Pikuri
  module Memory
    # Thin Faraday HTTP client against a self-hosted mem0 server
    # (the v3 "token-efficient" line — see ideas/memory-mem0.md). Only
    # the handful of REST endpoints pikuri needs are wired; the client
    # is hand-rolled rather than a dependency on a mem0 Ruby SDK
    # (there isn't a maintained one), Faraday is already in
    # pikuri-core's closure, and a thin first-party client keeps the
    # wire protocol auditable in one readable file. Same shape as
    # +pikuri-vectordb+'s +Backend::Chroma+.
    #
    # == Bring your own server
    #
    # +Client.new(endpoint:)+ points at an already-running mem0 server
    # (a docker-compose stack, a shared deployment). This release does
    # *not* ship a supervisor that starts one — that's the
    # +ChromaServer+-style follow-on. The server must be configured for
    # the local stack pikuri assumes: a local OpenAI-compatible LLM +
    # embedder (llama.cpp via +openai_base_url+), the **Qdrant** vector
    # backend (the pgvector path has a top-k inversion bug — see
    # ideas/memory-mem0.md §"Root cause"), and a non-reasoning
    # extraction model. Endpoints used:
    #
    # * +POST /memories+ — append. Body
    #   +{ messages:, user_id:, infer:, prompt? }+. Returns
    #   +{ "results": [{ id, memory, event }] }+.
    # * +POST /search+ — semantic recall. Body
    #   +{ query:, filters: { user_id: }, top_k:, threshold? }+.
    #   Returns +{ "results": [{ id, memory, score, created_at, ... }] }+,
    #   ranked nearest-first (Qdrant +score+ = similarity).
    # * +GET /memories?user_id=+ — every memory for a user (search
    #   row shape, minus +score+/+event+).
    # * +DELETE /memories/{id}+ — granular erase.
    # * +POST /reset+ — coarse erase (drop everything).
    #
    # == User-role content only (write-side hygiene)
    #
    # {#add} takes a single +content+ String and wraps it as one
    # +role: "user"+ message — it cannot send assistant/tool/system
    # turns. That's deliberate: feeding only the user's own words to
    # extraction structurally removes the dominant junk sources a
    # production mem0 audit measured (assistant restating, recalled-
    # memory feedback loops, involuntary secret leakage) — see
    # ideas/memory.md §"Extraction-input discipline". The rule lives
    # in the method signature so it can't be bypassed by accident.
    #
    # == Errors are loud
    #
    # Non-2xx responses and Faraday transport errors raise
    # +RuntimeError+ with the offending detail. The client doesn't
    # decide what's recoverable — its callers do: {Recall} turns a
    # failure into an +"Error: ..."+ observation the LLM can react to,
    # {Recorder} logs-and-drops so a transient mem0 blip never crashes
    # the capture worker, and {Extension}'s prefetch rescues to "inject
    # nothing this turn."
    class Client
      LOGGER = Pikuri.logger_for('Memory::Client')

      # @return [String] default mem0 server base URL — the server's
      #   own +:8000+ on localhost. A host running the dev
      #   docker-compose (which publishes +8888->8000+) passes that
      #   port explicitly; the supervisor follow-on will own the
      #   mapping.
      DEFAULT_ENDPOINT = 'http://localhost:8000'

      # @param endpoint [String] mem0 server base URL. +/memories+,
      #   +/search+, etc. are appended internally.
      # @param connection [Faraday::Connection, nil] dependency-
      #   injection hook for tests (wire +Faraday::Adapter::Test+ stubs
      #   here). Production callers leave it +nil+; a fresh JSON
      #   connection is built against +endpoint+.
      # @return [Client]
      # @raise [ArgumentError] on a blank +endpoint+.
      def initialize(endpoint: DEFAULT_ENDPOINT, connection: nil)
        raise ArgumentError, 'endpoint must be non-empty' if endpoint.nil? || endpoint.to_s.empty?

        @endpoint = endpoint
        @connection = connection || Faraday.new(url: endpoint) do |f|
          f.request :json
          f.response :json
          f.adapter Faraday.default_adapter
        end
      end

      # @return [String] the mem0 server base URL this client targets.
      attr_reader :endpoint

      # Append a memory. Wraps +content+ as one +role: "user"+ message
      # (the user-only rule — see the class header) and posts it for
      # extraction. mem0 is append-only: a correction is a *newer*
      # add, never a mutation of an earlier row (ideas/memory.md
      # §"The v1 write API collapses to one verb").
      #
      # @param content [String] the user's own words to extract from.
      # @param user_id [String] the mem0 namespace (one per user).
      # @param infer [Boolean] +true+ (default) stores LLM-extracted
      #   facts; +false+ stores the verbatim turn (the raw-log option,
      #   unused in v1).
      # @param prompt [String, nil] optional per-request
      #   +custom_fact_extraction_prompt+ override. {Extension} passes
      #   the curated +memory-extraction+ prompt here so a BYO server
      #   needn't be reconfigured.
      # @return [Array<Record>] the +add+ outcome rows (each carries an
      #   +event+: +"ADD"+ / +"UPDATE"+ / +"NONE"+ / ...). Empty when
      #   extraction found nothing worth storing.
      # @raise [ArgumentError] on blank +content+ or +user_id+.
      # @raise [RuntimeError] on HTTP failure.
      def add(content:, user_id:, infer: true, prompt: nil)
        raise ArgumentError, 'content must be non-empty' if content.nil? || content.to_s.strip.empty?
        raise ArgumentError, 'user_id must be non-empty' if user_id.nil? || user_id.to_s.empty?

        body = {
          messages: [{ role: 'user', content: content }],
          user_id: user_id,
          infer: infer
        }
        body[:prompt] = prompt if prompt && !prompt.empty?

        results_of(post_json('/memories', body))
      end

      # Semantic recall. Returns at most +top_k+ {Record}s ranked
      # nearest-first (mem0's Qdrant backend returns a similarity in
      # +score+; higher = more relevant).
      #
      # mem0 does *not* resolve contradictions at read time — it
      # returns the relevant memories (including a stale fact and its
      # correction) near-tied, and the consuming LLM resolves them at
      # synthesis. That's why {Record#created_at} rides along. See
      # ideas/memory-mem0.md §"Supersede recall on Qdrant".
      #
      # @param query [String] natural-language recall query (typically
      #   the latest user message, or a +recall+ topic).
      # @param user_id [String] the mem0 namespace to search.
      # @param top_k [Integer] max rows to return.
      # @param threshold [Float, nil] optional server-side similarity
      #   floor. +nil+ lets the server decide; {Extension} also
      #   filters client-side so the contract holds regardless.
      # @return [Array<Record>] ranked results; empty on no match.
      # @raise [ArgumentError] on blank +query+/+user_id+ or
      #   non-positive +top_k+.
      # @raise [RuntimeError] on HTTP failure.
      def search(query:, user_id:, top_k: 5, threshold: nil)
        raise ArgumentError, 'query must be non-empty' if query.nil? || query.to_s.strip.empty?
        raise ArgumentError, 'user_id must be non-empty' if user_id.nil? || user_id.to_s.empty?
        raise ArgumentError, "top_k must be positive (got #{top_k})" if top_k <= 0

        body = { query: query, filters: { user_id: user_id }, top_k: top_k }
        body[:threshold] = threshold unless threshold.nil?

        results_of(post_json('/search', body))
      end

      # Every memory stored for +user_id+, in mem0's order. Backs the
      # resident-persona summary and any future audit dump.
      #
      # @param user_id [String] the mem0 namespace.
      # @return [Array<Record>] all rows (no +score+, no +event+).
      # @raise [ArgumentError] on blank +user_id+.
      # @raise [RuntimeError] on HTTP failure.
      def get_all(user_id:)
        raise ArgumentError, 'user_id must be non-empty' if user_id.nil? || user_id.to_s.empty?

        response = @connection.get('/memories', { user_id: user_id })
        unless response.status == 200
          raise "Memory::Client: GET /memories returned HTTP #{response.status}: #{response.body.inspect}"
        end

        results_of(response.body)
      rescue Faraday::Error => e
        raise "Memory::Client: #{e.class.name.split('::').last} calling GET /memories: #{e.message}"
      end

      # Granular erase: physically remove one memory by id (the
      # privacy right-to-forget, user-gated at the caller). Idempotent
      # — a 404 is treated as "already gone".
      #
      # @param id [String] the {Record#id} to delete.
      # @return [void]
      # @raise [ArgumentError] on blank +id+.
      # @raise [RuntimeError] on HTTP failure other than 404.
      def delete(id:)
        raise ArgumentError, 'id must be non-empty' if id.nil? || id.to_s.empty?

        response = @connection.delete("/memories/#{id}")
        return if [200, 204, 404].include?(response.status)

        raise "Memory::Client: DELETE /memories/#{id} returned HTTP #{response.status}: #{response.body.inspect}"
      rescue Faraday::Error => e
        raise "Memory::Client: #{e.class.name.split('::').last} calling DELETE /memories/#{id}: #{e.message}"
      end

      # Coarse erase: drop *all* memories on the server. The blunt
      # right-to-forget (granular per-fact erase is {#delete}). Used by
      # tooling / tests, not on the agent path.
      #
      # @return [void]
      # @raise [RuntimeError] on HTTP failure.
      def reset!
        post_json('/reset', {})
        nil
      end

      private

      # Extract the +"results"+ array from a mem0 response body and map
      # each row to a {Record}. Tolerant of both shapes mem0 returns: a
      # +{ "results" => [...] }+ envelope (add / search) and a bare
      # array (some +get_all+ deployments).
      def results_of(body)
        rows = if body.is_a?(Hash)
                 body['results'] || []
               elsif body.is_a?(Array)
                 body
               else
                 []
               end
        rows.map { |row| Record.from(row) }
      end

      # JSON-POST helper shared by add / search / reset. Centralizes
      # the error shape and +Faraday::Error+ wrapping (same template as
      # +Backend::Chroma#post_json+).
      def post_json(path, body)
        response = @connection.post(path) do |req|
          req.headers['Content-Type'] = 'application/json'
          req.body = body
        end

        unless [200, 201].include?(response.status)
          raise "Memory::Client: POST #{path} returned HTTP #{response.status}: #{response.body.inspect}"
        end

        response.body
      rescue Faraday::Error => e
        raise "Memory::Client: #{e.class.name.split('::').last} calling POST #{path}: #{e.message}"
      end
    end
  end
end
