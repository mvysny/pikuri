# frozen_string_literal: true

module Pikuri
  module VectorDb
    # A unit of text after chunking, before storage. The {Indexer} pairs a Chunk
    # with its vector for {Backend#upsert}; {Tools::Search} surfaces query hits
    # as +Chunk+s wrapped in +Backend::Result+s.
    #
    # Fields:
    #
    # * +id+ — opaque backend-unique identifier, composed as +"source:offset"+
    #   (readable, deterministic, stable across reindexes). Incremental reindex
    #   replaces by +source+ not id, so the content hash rides in +metadata+,
    #   not the id. **Not for citation** — that's +source+; the LLM never sees +id+.
    # * +source+ — the user-facing reference (relative path, URL, connector doc
    #   ID), surfaced verbatim by {Tools::Search} as the citation. One source
    #   makes many chunks, so it is *not* unique within a backend — +id+ is.
    # * +text+ — the chunk content: fed to the embedder, surfaced to the LLM as
    #   the snippet.
    # * +metadata+ — free-form Hash of optional extras (+{ offset:, hash:,
    #   page:, ... }+); an open Hash since source types differ. The {Indexer}
    #   always sets +offset:+ and +hash:+ (SHA-256 of the file's bytes, same on
    #   every chunk of one file, so the sweep reads one chunk per source to know
    #   if the file changed). Surfaced to the LLM when present.
    #
    # No +vector+ field: the vector rides alongside only in transit between
    # {Embedder} and {Backend#upsert} and is absent on the query side (callers
    # see +Backend::Result+), so query chunks carry no inert +vector: nil+ and
    # +upsert+ takes the parallel-array shape backend clients already expect.
    # A frozen value object — partial reindex builds new Chunks with the same
    # +id+ and lets +#upsert+ overwrite.
    Chunk = Data.define(:id, :source, :text, :metadata)
  end
end
