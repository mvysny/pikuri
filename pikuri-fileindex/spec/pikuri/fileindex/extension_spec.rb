# frozen_string_literal: true

RSpec.describe Pikuri::Fileindex::Extension do
  # Records what the extension wires; it only adds tools.
  class FakeConfigurator
    attr_reader :tools

    def initialize = @tools = []
    def add_tool(tool) = @tools << tool
  end

  it 'wires both tools over the one backend and set of roots' do
    roots = Pikuri::Fileindex::Roots.new(dirs: [Dir.home], private: true, trusted: true)
    c = FakeConfigurator.new
    described_class.new(roots: roots, backend: FakeBackend.build).configure(c)

    assert_equal %w[fileindex_search fileindex_read], c.tools.map(&:name)
    assert_includes c.tools.first.description, "- #{Dir.home}\n"
    assert(c.tools.all? { |tool| tool.trifecta_legs == roots.legs })
  end
end
