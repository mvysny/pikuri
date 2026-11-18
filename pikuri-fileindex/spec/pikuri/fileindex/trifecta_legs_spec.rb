# frozen_string_literal: true

RSpec.describe 'file-index tool trifecta legs' do
  def tools(**declared)
    roots = Pikuri::Fileindex::Roots.new(dirs: [Dir.home], **declared)
    [Pikuri::Fileindex::Search.new(backend: FakeBackend.build, roots: roots),
     Pikuri::Fileindex::Read.new(backend: FakeBackend.build, roots: roots)]
  end

  it "grades both tools from the roots' declaration, never egress" do
    { {} => [false, :hard], { private: true } => [true, :hard],
      { private: true, trusted: true } => [true, :none] }.each do |declared, (private, untrusted)|
      tools(**declared).each do |tool|
        assert_equal private, tool.trifecta_legs.private, "#{tool.name} #{declared}"
        assert_equal untrusted, tool.trifecta_legs.untrusted, "#{tool.name} #{declared}"
        assert_equal :no_egress, tool.trifecta_legs.egress_payload_review, tool.name
      end
    end
  end
end
