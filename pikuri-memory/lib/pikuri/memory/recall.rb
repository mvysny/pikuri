# frozen_string_literal: true

module Pikuri
  module Memory
    # The +recall+ {Pikuri::Tool}: explicit, topic-driven deepening
    # beyond the automatic per-turn prefetch ({Extension#on_user_message}).
    # The "mined, deep" retrieval mode — the model calls it when the
    # prefetch slice hints there is more to find on a topic. Same
    # two-step agentic-RAG shape as +pikuri-vectordb+'s
    # +vectordb_search+ (cheap auto slice) + +vectordb_read+ (pull
    # more) — here, prefetch is the slice and +recall+ is the dig.
    #
    # == Single-param surface
    #
    # +recall(topic:)+ — no +top_k+, no +user_id+. Retrieval depth is
    # host policy baked into the {Extension}; the namespace is fixed at
    # construction. The model shouldn't tune retrieval mid-conversation;
    # a minimal surface is the deliberate choice (same rationale as
    # +vectordb_search+).
    #
    # == Recall does not resolve contradictions
    #
    # mem0 returns the relevant memories ranked by similarity, *not* by
    # recency, and keeps a stale fact alongside its correction. So the
    # observation carries each memory's +created_at+ timestamp and the
    # tool description tells the model to treat newer-about-the-same-
    # thing as current — resolution lives in the model's reasoning, not
    # in the store (ideas/memory-mem0.md §"Supersede recall on Qdrant").
    class Recall < Pikuri::Tool
      LOGGER = Pikuri.logger_for('Memory::Recall')

      # @return [Integer] memories returned per recall. A handful —
      #   enough to surface a topic's facts plus any correction, few
      #   enough to stay cheap in the turn.
      TOP_K = 7

      # @return [String] static description shown to the LLM,
      #   opencode-shape (summary + +Usage:+ bullets).
      DESCRIPTION = <<~DESC
        Search your durable memory of the user for facts relevant to a topic.

        Usage:
        - Use to recall what you know about the user or their work beyond what was automatically surfaced this turn — preferences, ongoing projects, people, decisions.
        - Phrase `topic` as a natural-language statement or question, e.g. "the user's current main project" or "how the user likes test output".
        - Each result carries a timestamp. Memory is append-only: if two results conflict, the more recent one is current truth — the older one is kept as history, not a contradiction to flag.
        - Returns up to #{TOP_K} memories. If nothing relevant comes back, say you don't have a memory of it rather than guessing.
      DESC

      # @param client [Client] the mem0 client recall queries go to.
      # @param user_id [String] the fixed mem0 namespace to search.
      # @return [Recall]
      def initialize(client:, user_id:)
        super(
          name: 'recall',
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_string :topic,
                              'Natural-language topic or question to recall about the user, e.g. ' \
                              '"the user\'s dietary preferences" or "what project are we working on?".'
          },
          execute: lambda { |topic:|
            Recall.execute(client: client, user_id: user_id, topic: topic)
          }
        )
      end

      # Public so specs can exercise recall without constructing a Tool
      # wrapper. Catches {Client} failures and renders them as an
      # +"Error: ..."+ observation the LLM can react to (a transient
      # mem0 blip shouldn't crash the loop) — bugs in pikuri's own code
      # still raise.
      #
      # @param client [Client]
      # @param user_id [String]
      # @param topic [String]
      # @return [String] formatted observation.
      def self.execute(client:, user_id:, topic:)
        return 'Error: topic is empty' if topic.nil? || topic.strip.empty?

        records = client.search(query: topic, user_id: user_id, top_k: TOP_K)
        return 'No relevant memories found.' if records.empty?

        format_observation(records)
      rescue RuntimeError => e
        LOGGER.warn("recall failed: #{e.message}")
        "Error: memory recall failed: #{e.message}"
      end

      # Format the recalled memories as a header + one line per memory,
      # each prefixed with its +created_at+ date so the model can apply
      # recency when two memories about the same thing conflict.
      #
      # @param records [Array<Record>]
      # @return [String]
      def self.format_observation(records)
        header = "Recalled #{records.length} " \
                 "memor#{records.length == 1 ? 'y' : 'ies'}:\n"
        body = records.map do |r|
          when_ = r.created_at ? "(#{r.created_at}) " : ''
          "- #{when_}#{r.text}"
        end.join("\n")
        header + body
      end
      private_class_method :format_observation
    end
  end
end
