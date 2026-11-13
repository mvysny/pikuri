# frozen_string_literal: true

module Pikuri
  module VectorDb
    # Namespace for the vector-database supervisors — one per {Backend} engine,
    # named to pair ({Backend::Qdrant} ↔ {Server::Qdrant}, etc.). The backend
    # owns the store protocol; the server owns its *lifetime*. All three
    # implement the same duck-typed protocol (+.ensure_running+ /
    # +#ensure_running!+ / +#client(collection:)+ / +#close+), so a host chains
    # +ensure_running.client(...)+ and closes at teardown without branching per
    # engine.
    #
    # For {Qdrant} / {Chroma} the lifetime is a podman/docker container, both composing
    # the shared {Container} helper so each supervisor is just the
    # engine's identity. {InMemory} is the null supervisor (no process, just the
    # in-process store registry). Hosts already running an engine construct the
    # backend directly and never touch this namespace.
    #
    # Only *supervisors* (and {Container}) live here. Classes with "server"
    # in the name that are actually HTTP *clients* — {Reranker::LlamaServer},
    # {Tokenizer::LlamaServer} — stay in their feature namespaces.
    module Server
    end
  end
end
