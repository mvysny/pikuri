# frozen_string_literal: true

RSpec.describe Pikuri::Skill::Extension do
  # Minimal stand-in for a non-empty catalog — same shape used in
  # agent_spec.rb's skill_catalog wiring section, lifted here so
  # these specs don't need on-disk skill files.
  let(:fake_catalog_class) do
    Class.new(Pikuri::Skill::Catalog) do
      def initialize(skills)
        super()
        @skills = skills
      end

      def list
        @skills
      end

      def get(name)
        @skills.find { |s| s.name == name }
      end
    end
  end

  let(:sample_skill) do
    Pikuri::Skill::Catalog::Skill.new(
      name: 'sample',
      description: 'Sample skill description.',
      location: '/tmp/sample/SKILL.md',
      body: 'do the thing.'
    )
  end

  let(:non_empty_catalog) { fake_catalog_class.new([sample_skill]) }
  let(:empty_catalog) { Pikuri::Skill::Catalog::EMPTY }

  let(:configurator) do
    Pikuri::Agent::Configurator.new(
      transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
      system_prompt_base: 'base',
      id: '',
      streaming: false,
      step_limit: nil,
      cancellable: nil,
      interloper: nil
    )
  end

  it 'is an Agent::Extension by composition' do
    ext = described_class.new(catalog: non_empty_catalog)
    assert_kind_of Pikuri::Agent::Extension, ext
  end

  describe '#configure' do
    it 'appends the catalog block to the system prompt and registers Skill::SkillTool (non-empty catalog)' do
      ext = described_class.new(catalog: non_empty_catalog)
      ext.configure(configurator)

      assert_equal 1, configurator.system_prompt_additions.size
      snippet = configurator.system_prompt_additions.first
      # The snippet itself must not start with blank lines — the
      # Configurator handles the separator at drain time.
      refute snippet.start_with?("\n"), 'snippet should be lstripped'
      assert snippet.include?('<available_skills>'), snippet
      assert snippet.include?('<name>sample</name>'), snippet

      assert_equal 1, configurator.tools.size
      tool = configurator.tools.first
      assert_kind_of Pikuri::Skill::SkillTool, tool
    end

    it 'is a no-op when the catalog is empty' do
      ext = described_class.new(catalog: empty_catalog)
      ext.configure(configurator)

      assert_equal [], configurator.system_prompt_additions
      assert_equal [], configurator.tools
    end

    it 'raises if Pikuri::Skill::SkillTool was already pre-registered via c.add_tool' do
      configurator.add_tool(Pikuri::Skill::SkillTool.new(catalog: non_empty_catalog))
      ext = described_class.new(catalog: non_empty_catalog)

      err = assert_raises(RuntimeError) { ext.configure(configurator) }
      assert_match(/auto-registers/, err.message)
    end
  end

  describe '#bind' do
    it 'is the inherited no-op default — Skills has no per-agent state' do
      ext = described_class.new(catalog: non_empty_catalog)
      assert_nil ext.bind(:any_agent)
    end
  end

  describe '#catalog' do
    it 'exposes the catalog passed at construction' do
      ext = described_class.new(catalog: non_empty_catalog)
      assert_same non_empty_catalog, ext.catalog
    end
  end
end
