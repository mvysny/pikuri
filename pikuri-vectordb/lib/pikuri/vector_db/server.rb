# frozen_string_literal: true

module Pikuri
  module VectorDb
    # Namespace for the vector-database supervisors — one per
    # {Backend} engine, named to pair: {Backend::InMemory} ↔
    # {Server::InMemory}, {Backend::Qdrant} ↔ {Server::Qdrant},
    # {Backend::Chroma} ↔ {Server::Chroma}. The backend owns the
    # store protocol (upsert/query/...); the server owns the
    # store's *lifetime*. All three implement the same duck-typed
    # Server protocol — +.ensure_running+ / +#ensure_running!+ /
    # +#client(collection:)+ / +#close+ — so a host picks a Server
    # class, chains +ensure_running.client(...)+, and closes it at
    # teardown without branching per engine.
    #
    # For {Qdrant} and {Chroma} the lifetime is a docker container
    # (create / recreate / remove, bind-mount the data dir,
    # heartbeat-poll until ready) — both compose the shared
    # {DockerContainer} lifecycle helper, keeping each supervisor
    # down to the engine's identity (image pin, container name,
    # persist path, heartbeat path). {InMemory} is the null
    # supervisor: no process at all, just the registry of
    # in-process stores. Hosts that already run an engine
    # elsewhere construct the backend directly and never touch
    # this namespace.
    #
    # Only *supervisors* (and {DockerContainer}, their shared
    # lifecycle engine) live here. Classes with "server" in the
    # name that are actually HTTP *clients* against a process the
    # user runs — {Reranker::LlamaServer}, {Tokenizer::LlamaServer}
    # — stay in their feature namespaces.
    module Server
    end
  end
end
