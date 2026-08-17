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
  let(:root) { Pathname.new(Dir.pwd) }

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
    ext = described_class.new(catalog: non_empty_catalog, root: root)
    assert_kind_of Pikuri::Agent::Extension, ext
  end

  describe '#configure / #system_prompt_snippets' do
    it 'contributes the catalog block and registers Skill::SkillTool (non-empty catalog)' do
      ext = described_class.new(catalog: non_empty_catalog, root: root)
      ext.configure(configurator)

      assert_equal 1, ext.system_prompt_snippets.size
      snippet = ext.system_prompt_snippets.first
      # The snippet itself must not start with blank lines — the
      # Agent handles the separator at assembly time.
      refute snippet.start_with?("\n"), 'snippet should be lstripped'
      assert snippet.include?('<available_skills>'), snippet
      assert snippet.include?('<name>sample</name>'), snippet

      assert_equal 1, configurator.tools.size
      tool = configurator.tools.first
      assert_kind_of Pikuri::Skill::SkillTool, tool
    end

    it 'is a no-op when the catalog is empty' do
      ext = described_class.new(catalog: empty_catalog, root: root)
      ext.configure(configurator)

      assert_equal [], ext.system_prompt_snippets
      assert_equal [], configurator.tools
    end

    it 'raises if Pikuri::Skill::SkillTool was already pre-registered via c.add_tool' do
      configurator.add_tool(Pikuri::Skill::SkillTool.new(catalog: non_empty_catalog))
      ext = described_class.new(catalog: non_empty_catalog, root: root)

      err = assert_raises(RuntimeError) { ext.configure(configurator) }
      assert_match(/auto-registers/, err.message)
    end
  end

  describe '#bind / #schedule_load_skill' do
    let(:interloper) { Pikuri::Agent::Control::Interloper.new }

    # Minimal ExtensionContext stand-in: schedule_load_skill only reaches
    # ctx.agent.interloper.
    def ctx_reaching(interloper)
      agent = Struct.new(:interloper).new(interloper)
      Struct.new(:agent).new(agent)
    end

    it 'captures the agent interloper on bind, then enqueues a :system skill block' do
      ext = described_class.new(catalog: non_empty_catalog, root: root)
      ext.bind(ctx_reaching(interloper))

      returned = ext.schedule_load_skill('sample')

      assert_same sample_skill, returned
      pending = interloper.peek
      assert_equal 1, pending.size
      assert_equal :system, pending.first.kind
      assert pending.first.content.include?('<skill name="sample"'), pending.first.content
      assert pending.first.content.include?('do the thing.'), pending.first.content
    end

    it 'raises KeyError for a name absent from the catalog, enqueuing nothing' do
      ext = described_class.new(catalog: non_empty_catalog, root: root)
      ext.bind(ctx_reaching(interloper))

      assert_raises(KeyError) { ext.schedule_load_skill('no-such-skill') }
      assert_equal [], interloper.peek
    end

    it 'raises when the agent was built without an interloper' do
      ext = described_class.new(catalog: non_empty_catalog, root: root)
      ext.bind(ctx_reaching(nil))

      err = assert_raises(RuntimeError) { ext.schedule_load_skill('sample') }
      assert_match(/interloper/, err.message)
    end
  end

  describe '#catalog / #root' do
    it 'exposes the catalog passed at construction' do
      ext = described_class.new(catalog: non_empty_catalog, root: root)
      assert_same non_empty_catalog, ext.catalog
    end

    it 'exposes the workspace root passed at construction' do
      ext = described_class.new(catalog: non_empty_catalog, root: root)
      assert_equal root, ext.root
    end

    it 'refuses a root that is not a Pathname' do
      err = assert_raises(ArgumentError) { described_class.new(catalog: non_empty_catalog, root: Dir.pwd) }
      assert_match(/absolute Pathname/, err.message)
    end

    it 'refuses a relative root, since a model-supplied path resolves against it' do
      err = assert_raises(ArgumentError) do
        described_class.new(catalog: non_empty_catalog, root: Pathname.new('lib'))
      end
      assert_match(/absolute Pathname/, err.message)
    end
  end

  describe '#activation' do
    let(:gated_skill) do
      Pikuri::Skill::Catalog::Skill.new(
        name: 'gated',
        description: 'Gated skill description.',
        location: '/tmp/gated/SKILL.md',
        body: 'do the gated thing.',
        paths: ['**/*.rb']
      )
    end

    let(:ext) do
      described_class.new(catalog: fake_catalog_class.new([sample_skill, gated_skill]), root: root)
    end

    it 'is a view over the same catalog, withholding the gated skills' do
      assert_same ext.catalog, ext.activation.catalog
      assert_equal ['sample'], ext.activation.names
    end

    it 'clears on a conversation reset, so the next touch announces again' do
      ext.activation.activate([gated_skill])
      assert ext.activation.in_play?('gated')

      ext.on_conversation_reset(nil)

      refute ext.activation.in_play?('gated')
    end
  end
end
