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

  describe '#needs_temp_workspace' do
    it 'defaults to false when not supplied' do
      persona = described_class.new(**base_attrs)
      assert_equal false, persona.needs_temp_workspace
    end

    it 'accepts true and exposes it via the accessor' do
      persona = described_class.new(**base_attrs, needs_temp_workspace: true)
      assert_equal true, persona.needs_temp_workspace
    end
  end

  describe '#needs_temp_workspace? (predicate alias)' do
    it 'returns the same value as #needs_temp_workspace' do
      off = described_class.new(**base_attrs)
      on  = described_class.new(**base_attrs, needs_temp_workspace: true)

      refute_predicate off, :needs_temp_workspace?
      assert_predicate on, :needs_temp_workspace?
    end
  end

  describe 'Data semantics' do
    it 'is immutable — produces a new instance via #with' do
      persona = described_class.new(**base_attrs)
      forked = persona.with(needs_temp_workspace: true)

      refute_equal persona.object_id, forked.object_id
      assert_equal false, persona.needs_temp_workspace
      assert_equal true,  forked.needs_temp_workspace
    end
  end
end
