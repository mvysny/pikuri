# frozen_string_literal: true

require 'time'

module Pikuri
  module Memory
    # One memory row as returned by a mem0 server, normalized into a
    # plain value object. The same shape backs all three read/write
    # surfaces — +add+ (carries +event+, no +score+), +search+
    # (carries +score+, no +event+), and +get_all+ (neither) — with
    # the absent fields left +nil+, so callers can pattern-match on
    # what's present rather than juggling three near-identical types.
    #
    # == Field provenance (mem0 v3 JSON → this)
    #
    # * +id+ ← +"id"+ — the memory's UUID; the handle for +delete+.
    # * +text+ ← +"memory"+ — the fact string. Named +text+ here
    #   because +memory+ would shadow the enclosing module and read
    #   oddly (+record.memory+).
    # * +score+ ← +"score"+ — similarity on the Qdrant backend
    #   (higher = more relevant; the v1 backend, see
    #   DESIGN.md §"Why Qdrant, not pgvector"). +nil+ outside +search+ results.
    # * +created_at+ ← +"created_at"+ — ISO-8601 String as mem0
    #   emits it. Load-bearing for recall: contradiction resolution
    #   happens in the *consuming* LLM's synthesis, and recency is
    #   its tiebreaker, so the timestamp must travel with the recalled
    #   text (DESIGN.md §"Supersede recall: resolution is the consumer's job").
    # * +metadata+ ← +"metadata"+ — arbitrary Hash; +{}+ when absent.
    # * +event+ ← +"event"+ — +"ADD"+ / +"UPDATE"+ / +"DELETE"+ /
    #   +"NONE"+ on an +add+ response; +nil+ on reads.
    Record = Data.define(:id, :text, :score, :created_at, :metadata, :event) do
      # Build a {Record} from one mem0 result Hash (String keys, as
      # Faraday's JSON middleware deserializes them). Tolerant of
      # missing keys — every field but +metadata+ defaults to +nil+,
      # and +metadata+ to +{}+ — so the one factory serves +add+ /
      # +search+ / +get_all+ rows alike.
      #
      # @param hash [Hash] one element of a mem0 +"results"+ array
      # @return [Record]
      def self.from(hash)
        new(
          id: hash['id'],
          text: hash['memory'],
          score: hash['score'],
          created_at: hash['created_at'],
          metadata: hash['metadata'] || {},
          event: hash['event']
        )
      end

      # +created_at+ trimmed to whole-second wall-clock for the
      # prompt: +"2026-06-01T17:04:11.884889+00:00"+ →
      # +"2026-06-01 17:04:11"+. Recall uses the timestamp only as a
      # recency tiebreaker (see +created_at+'s field note), so the
      # sub-second precision and +T+/offset machinery are noise in
      # the context window — a shorter date reads cleaner for the
      # model and costs fewer tokens. Returns +nil+ when +created_at+
      # is absent (+add+ / +search+ rows that omit it), and falls
      # back to the raw String if mem0 ever emits an unparseable
      # value (degraded display, not a pikuri bug).
      #
      # @return [String, nil]
      def created_label
        return nil unless created_at

        Time.parse(created_at).strftime('%Y-%m-%d %H:%M:%S')
      rescue ArgumentError
        created_at
      end
    end
  end
end
