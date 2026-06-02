# frozen_string_literal: true

module Pikuri
  module VectorDb
    # Namespace for the self-managed vector-database supervisors —
    # one per persistent {Backend} engine, named to pair:
    # {Backend::Qdrant} ↔ {Server::Qdrant}, {Backend::Chroma} ↔
    # {Server::Chroma}. The backend owns the HTTP wire protocol;
    # the server owns the docker process (create / recreate /
    # remove the container, bind-mount the data dir,
    # heartbeat-poll until ready). Hosts that already run an
    # engine elsewhere construct the backend directly and never
    # touch this namespace.
    #
    # Only *supervisors* live here. Classes with "server" in the
    # name that are actually HTTP *clients* against a process the
    # user runs — {Reranker::LlamaServer}, {Tokenizer::LlamaServer}
    # — stay in their feature namespaces.
    module Server
    end
  end
end
