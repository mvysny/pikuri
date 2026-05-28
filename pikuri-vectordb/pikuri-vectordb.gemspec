# frozen_string_literal: true

require_relative '../pikuri-core/lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-vectordb'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Local-corpus vector search + agentic RAG for pikuri.'
  spec.description = <<~DESC
    pikuri-vectordb gives a pikuri-core agent a +vectordb_search+
    tool over a local document corpus — agentic search, the agent
    decides when to retrieve. Ships a swappable backend (a
    pure-Ruby +Backend::InMemory+ for teaching and a thin
    +Backend::Chroma+ HTTP client for persistence), a chunker, an
    embedder wrapper over +RubyLLM.embed+, and an optional
    +Reranker::LlamaServer+ that speaks +/v1/rerank+ against a
    cross-encoder model. Text extraction goes through
    +Pikuri::FileType.read_as_text+ in pikuri-core, which handles
    plain text / Markdown / PDF; HTML extraction is a deferred
    follow-up. Hosts wire the feature via
    +c.add_extension Pikuri::VectorDb::Extension.new(...)+ inside
    the +Agent.new+ block — same opt-in shape as +pikuri-tasks+ /
    +pikuri-skills+. The bundled +Pikuri::VectorDb::LIBRARIAN+
    persona is the privilege-separated sub-agent counterpart for
    hosts that want recall to flow through a child rather than the
    parent's context.

    Three model endpoints in the full setup — chat (via ruby_llm),
    an embedder (via +RubyLLM.embed+), and an optional reranker
    (HTTP +/v1/rerank+). A single +llama-server+ in router mode
    serves all three by default, loading each cached GGUF on
    demand; see the gem's README for details.
  DESC

  spec.homepage = 'https://codeberg.org/mvysny/pikuri'
  spec.license  = 'MIT'

  spec.required_ruby_version = '>= 3.3'

  spec.metadata = {
    'source_code_uri'       => "#{spec.homepage}/src/branch/master",
    'changelog_uri'         => "#{spec.homepage}/src/branch/master/CHANGELOG.md",
    'bug_tracker_uri'       => "#{spec.homepage}/issues",
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir[
    'lib/**/*.rb',
    'prompts/*.txt',
    'LICENSE',
    'README.md'
  ]
  spec.require_paths = ['lib']

  # pikuri-core ships the +Agent+ runtime + +Pikuri::Tool+ base
  # class that the search tool subclasses, +RubyLLM.embed+ wired
  # through ruby_llm, Faraday for HTTP, and +pdf-reader+ /
  # +reverse_markdown+ for the PDF / HTML text extraction the
  # indexer reuses.
  spec.add_dependency 'pikuri-core', "= #{Pikuri::VERSION}"
  # pikuri-subagents ships +Pikuri::SubAgent::Persona+, the value
  # type the bundled +LIBRARIAN+ persona constant is an instance
  # of. Hosts that want LIBRARIAN spawnable wire it via
  # +SubAgent::Extension.new(personas: [..., LIBRARIAN])+ — same
  # shape +pikuri-code+ uses for +GIT_REPO_RESEARCHER+.
  spec.add_dependency 'pikuri-subagents', "= #{Pikuri::VERSION}"
end
