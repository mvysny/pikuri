# frozen_string_literal: true

RSpec.describe Pikuri::SubAgent::Persona do
  let(:base_attrs) do
    {
      name: 'fake',
      description: 'd',
      tool_names: %w[web_search],
      system_prompt: 's',
      max_steps: 5
    }
  end

  describe '#workspace_builder' do
    it 'defaults to nil when not supplied' do
      persona = described_class.new(**base_attrs)
      assert_nil persona.workspace_builder
    end

    it 'accepts a Proc and exposes it via the accessor' do
      builder = ->(_path) { :workspace_stub }
      persona = described_class.new(**base_attrs, workspace_builder: builder)
      assert_same builder, persona.workspace_builder
    end
  end

  describe '#needs_temp_workspace?' do
    it 'is false when workspace_builder is nil' do
      persona = described_class.new(**base_attrs)
      refute_predicate persona, :needs_temp_workspace?
    end

    it 'is true when workspace_builder is set' do
      persona = described_class.new(**base_attrs, workspace_builder: ->(_) { :w })
      assert_predicate persona, :needs_temp_workspace?
    end
  end

  describe 'Data semantics' do
    it 'is immutable — produces a new instance via #with' do
      persona = described_class.new(**base_attrs)
      builder = ->(_p) { :w }
      forked = persona.with(workspace_builder: builder)

      refute_equal persona.object_id, forked.object_id
      assert_nil persona.workspace_builder
      assert_same builder, forked.workspace_builder
    end
  end
end
