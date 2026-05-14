# frozen_string_literal: true

RSpec.describe Pikuri::Tool::Skill do
  FIXTURE_VALID = File.expand_path('../../fixtures/skills/valid-tree', __dir__)

  let(:catalog) { Pikuri::Tool::SkillCatalog::Bundled.new(roots: [FIXTURE_VALID]) }

  describe 'tool shape' do
    it 'is named "skill" and exposes a required `name` string parameter' do
      tool = described_class.new(catalog: catalog)

      assert_kind_of Pikuri::Tool, tool
      assert_equal 'skill', tool.name
      schema = tool.parameters.to_h
      assert_equal ['name'], schema[:required]
      assert_equal 'string', schema[:properties][:name][:type]
    end

    it "uses a static description that points to the system prompt's catalog" do
      tool = described_class.new(catalog: catalog)
      assert tool.description.include?('available_skills'),
             "expected static description to point the LLM at the prompt's catalog, got: #{tool.description}"
    end
  end

  describe 'execution' do
    it 'returns the skill body wrapped with the base directory when the name resolves' do
      tool = described_class.new(catalog: catalog)
      out = tool.run('name' => 'pdf-tools')

      assert out.include?('<skill name="pdf-tools"'), out
      assert out.include?('pdftotext'), out
      assert out.include?(File.join(FIXTURE_VALID, 'pdf-tools')), out
      assert out.include?('</skill>'), out
    end

    it 'returns an LLM-actionable Error: string for an unknown name, listing what is available' do
      tool = described_class.new(catalog: catalog)
      out = tool.run('name' => 'no-such-skill')

      assert out.start_with?('Error:'), out
      assert out.include?("'no-such-skill'"), out
      # The hint must enumerate every skill the catalog knows about so
      # the LLM can recover on the next turn without guessing.
      assert out.include?('pdf-tools'), out
      assert out.include?('data-viz'), out
    end

    it 'returns an Error: string mentioning "none" when the catalog is empty' do
      tool = described_class.new(catalog: Pikuri::Tool::SkillCatalog::EMPTY)
      out = tool.run('name' => 'anything')

      assert out.start_with?('Error:'), out
      assert out.include?('none'), out
    end

    it 'reports a validation error for the wrong argument shape (not raised, not crashed)' do
      tool = described_class.new(catalog: catalog)
      out = tool.run({})

      assert out.start_with?('Error:'), out
      assert out.include?('name'), out
    end
  end
end
