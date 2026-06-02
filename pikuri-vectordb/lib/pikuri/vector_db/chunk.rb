# frozen_string_literal: true

module Pikuri
  module VectorDb
    # A unit of text after chunking, before storage. The
    # {Indexer} composes a Chunk + its vector and hands the pair
    # to a {Backend} for storage; {Tools::Search} surfaces query hits
    # back to the LLM as +Chunk+s wrapped in +Backend::Result+s.
    #
    # == Fields
    #
    # * +id+ — opaque internal identifier, unique within a
    #   backend. The {Indexer} composes it as +"source:offset"+
    #   (the relative source path plus the chunk's ordinal within
    #   that file) — readable in logs, deterministic, and stable
    #   across reindexes of the same file. Incremental reindex
    #   replaces a whole document by +source+ (not by id), so the
    #   file's content hash rides in +metadata+ rather than in the
    #   id — see +metadata+ below. **Not for citation** — that's
    #   +source+'s job; the LLM never sees +id+.
    # * +source+ — user-facing reference for what was indexed.
    #   Relative file path for filesystem sources
    #   (+"notes/cooking.md"+), URL for fetched docs, doc ID for
    #   future connector sources (Google Drive, Notion). Surfaced
    #   verbatim by {Tools::Search} as the citation alongside each hit;
    #   the LLM uses it to say "see notes/cooking.md" rather than
    #   answering from a chunk of unknown origin. One source
    #   typically produces many chunks (a 512-token sliding
    #   window over a 20 KB Markdown file ≈ 10 chunks), so
    #   +source+ is not unique within a backend — that's the
    #   +id+'s role.
    # * +text+ — the chunk's text content; the unit fed to the
    #   embedder for vectorization, and surfaced verbatim to the
    #   LLM as the snippet alongside its +source+ citation.
    # * +metadata+ — free-form Hash for the optional extras that
    #   some source types carry: +{ offset:, hash:, page:, ... }+.
    #   Not every source type needs every field, so the open Hash
    #   beats a fixed shape. The {Indexer} always sets +offset:+
    #   (ordinal within the file) and +hash:+ (SHA-256 of the source
    #   file's bytes — the same for every chunk of one file, so the
    #   incremental sweep can read one chunk per source and know
    #   whether the file changed). Surfaced to the LLM in the search
    #   observation when present.
    #
    # == Why no vector field
    #
    # The vector lives alongside the chunk only in transit between
    # {Embedder} and {Backend#upsert}, and disappears from view on
    # the query side (callers see +Backend::Result+ with a chunk +
    # a score, never the raw vector). Keeping it off +Chunk+ means
    # query-result chunks carry no inert +vector: nil+ field, and
    # the +upsert+ API takes parallel arrays the same shape every
    # backend's underlying client (Chroma's Python +collection.upsert+
    # included) already expects.
    #
    # == Why a Data.define
    #
    # Immutable value types match pikuri's convention for similar
    # records (+Persona+, the various +Event+ types). A Chunk
    # cannot be mutated after construction; partial-reindex flows
    # build new Chunks with the same +id+ and let the backend
    # +#upsert+ overwrite the old text + vector.
    Chunk = Data.define(:id, :source, :text, :metadata)
  end
end
