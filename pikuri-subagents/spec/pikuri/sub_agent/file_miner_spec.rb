# frozen_string_literal: true

RSpec.describe Pikuri::SubAgent::FILE_MINER do
  it 'is a Persona record named "file_miner"' do
    assert_kind_of Pikuri::SubAgent::Persona, described_class
    assert_equal 'file_miner', described_class.name
  end

  it 'declares read-only fs tool_names — no egress, no mutation, no agent recursion' do
    assert_equal %w[read grep glob], described_class.tool_names
  end

  it 'loads its system prompt from pikuri-subagents/prompts/persona-file-miner.txt' do
    refute_predicate described_class.system_prompt, :empty?
    assert_match(/recon sub-agent/i, described_class.system_prompt)
  end

  it 'has a step budget suited to fs recon (glob + multi-pass grep + read)' do
    assert_kind_of Integer, described_class.max_steps
    assert described_class.max_steps.positive?
  end

  describe 'integration with Pikuri::SubAgent::Extension' do
    # Stub tools whose names match FILE_MINER.tool_names. Hand-rolled
    # rather than pulling in the real Pikuri::Workspace::Read / Grep /
    # Glob so pikuri-subagents stays decoupled from pikuri-workspace at
    # both the runtime-dep level (IDEAS.md "File-miner persona") and the
    # test-closure level.
    def stub_tool(name)
      Pikuri::Tool.new(
        name:        name,
        description: "stub for #{name}",
        parameters:  Pikuri::Tool::Parameters.build { |_| },
        execute:     ->(**_) { '' }
      )
    end

    let(:tools) { %w[read grep glob].map { |n| stub_tool(n) } }

    let(:configurator) do
      Pikuri::Agent::Configurator.new(
        transport:          Pikuri::Agent::ChatTransport.new(model: 'm'),
        system_prompt_base: 'base',
        id:                 '',
        streaming:          false,
        step_limit:         nil,
        cancellable:        nil,
        interloper:         nil
      )
    end

    it 'configures cleanly when read/grep/glob are present' do
      tools.each { |t| configurator.add_tool(t) }
      ext = Pikuri::SubAgent::Extension.new(personas: [described_class])
      # No raise — the persona's tool_names are a subset of registered tools.
      ext.configure(configurator)
      assert_equal ['file_miner'], ext.personas.keys
    end

    it "raises Extension#configure when one of the persona's tools is missing" do
      configurator.add_tool(stub_tool('read'))
      # grep and glob deliberately missing
      ext = Pikuri::SubAgent::Extension.new(personas: [described_class])

      err = assert_raises(ArgumentError) { ext.configure(configurator) }
      assert_match(/grep/, err.message)
      assert_match(/glob/, err.message)
    end
  end
end
