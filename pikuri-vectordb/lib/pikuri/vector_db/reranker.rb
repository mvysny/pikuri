# frozen_string_literal: true

module Pikuri
  module VectorDb
    # Namespace for rerankers — the optional quality knob that
    # narrows a top-N candidate set (typically 50) down to the
    # top-k the LLM actually sees (typically 5) by scoring each
    # candidate's relevance to the query with a cross-encoder
    # model. One ships in v1:
    #
    # * {LlamaServer} — Faraday POST +/v1/rerank+ against a
    #   cross-encoder model on a llama.cpp server. Same wire
    #   format Cohere's hosted reranker speaks, so adding a
    #   +Reranker::Cohere+ later is a thin adapter (see
    #   IDEAS.md §"Vector DB / RAG" → "Deferred").
    #
    # == Reranker protocol
    #
    # Duck-typed, single method:
    #
    # * +#rerank(query:, documents:)+ — return an
    #   +Array<{Hit}>+ sorted by descending +score+; one entry
    #   per input document (or fewer if the server truncates,
    #   but typical reranker behaviour is "score every input").
    #   +documents+ is an +Array<String>+; the +Hit.index+ is
    #   the position in that input array. Empty +documents+
    #   short-circuits to +[]+ without an HTTP call.
    #
    # == Why index, not document text
    #
    # The {Search} tool already holds the candidate
    # +Backend::Result+s with their text + metadata. Returning
    # bare indices keeps the rerank API minimal and avoids
    # re-shuttling the document text over HTTP just to receive
    # it back — Cohere's +return_documents+ flag exists exactly
    # for callers that don't already have the text, which isn't
    # us. Index+score is enough; document+score can be
    # reconstructed by the caller.
    #
    # == Why nil-skip rather than a NOOP default
    #
    # +Pikuri::VectorDb::Extension+ accepts +reranker: nil+ as
    # "skip rerank entirely; retrieve top-k from the backend
    # directly." A +Reranker::NOOP+ that returns the input
    # ordering with synthetic scores was considered and
    # rejected: it doesn't unify the candidate-window choice
    # (we'd either waste vector lookups by always fetching top-N
    # or branch anyway on whether the reranker is "real"), and
    # the faux scores would pollute observation formatting and
    # debug logs.
    module Reranker
    end
  end
end
