# frozen_string_literal: true

RSpec.describe 'vectordb tool trifecta legs' do
  it 'is hard untrusted with no egress — a corpus is documents pikuri did not write' do
    tools = [Pikuri::VectorDb::Tools::Search.new(embedder: nil, backend: nil, reranker: nil),
             Pikuri::VectorDb::Tools::Read.new(backend: nil, root: nil),
             Pikuri::VectorDb::Tools::Reindex.new(indexer: nil)]
    tools.each do |tool|
      assert_equal :hard, tool.trifecta_legs.untrusted, tool.name
      assert_equal :none, tool.trifecta_legs.egress, tool.name
    end
  end

  it 'claims no private leg — there is no per-corpus declaration yet' do
    # A private corpus is under-warned. Documented at the declaration rather
    # than guessed at here; see Filesystem#private? for the shape it would take.
    refute Pikuri::VectorDb::Tools::Search.new(embedder: nil, backend: nil, reranker: nil)
                                          .trifecta_legs.private
  end
end
