# frozen_string_literal: true

RSpec.describe Pikuri::SubAgent::RESEARCHER do
  it 'is a Persona record named "researcher"' do
    assert_kind_of Pikuri::SubAgent::Persona, described_class
    assert_equal 'researcher', described_class.name
  end

  it 'declares web-only tool_names — no fs, no shell, no agent recursion' do
    assert_equal %w[web_search web_scrape fetch], described_class.tool_names
  end

  it 'loads its system prompt from pikuri-subagents/prompts/persona-researcher.txt' do
    refute_predicate described_class.system_prompt, :empty?
    assert_match(/research sub-agent/i, described_class.system_prompt)
  end

  describe 'integration with Pikuri::SubAgent::Extension' do
    let(:tools) do
      [Pikuri::Tool::WebSearch.build, Pikuri::Tool::WEB_SCRAPE, Pikuri::Tool::FETCH]
    end

    let(:configurator) do
      Pikuri::Agent::Configurator.new(
        transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
        system_prompt_base: 'base',
        id: '',
        streaming: false,
        cancellable: nil,
        interloper: nil
      )
    end

    it 'configures cleanly when the three bundled web tools are present' do
      tools.each { |t| configurator.add_tool(t) }
      ext = Pikuri::SubAgent::Extension.new(personas: [described_class])
      # No raise — the persona's tool_names are a subset of registered tools.
      ext.configure(configurator)
      assert_equal ['researcher'], ext.personas.keys
    end

    it "raises Extension#configure when one of the persona's tools is missing" do
      configurator.add_tool(Pikuri::Tool::WebSearch.build)
      # web_scrape and fetch deliberately missing
      ext = Pikuri::SubAgent::Extension.new(personas: [described_class])

      err = assert_raises(ArgumentError) { ext.configure(configurator) }
      assert_match(/web_scrape/, err.message)
      assert_match(/fetch/, err.message)
    end
  end
end
