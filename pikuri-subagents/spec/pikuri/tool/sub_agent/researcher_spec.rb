# frozen_string_literal: true

RSpec.describe Pikuri::Tool::SubAgent::RESEARCHER do
  it 'is a Persona record named "researcher"' do
    assert_kind_of Pikuri::Tool::SubAgent::Persona, described_class
    assert_equal 'researcher', described_class.name
  end

  it 'declares web-only tool_names — no fs, no shell, no agent recursion' do
    assert_equal %w[web_search web_scrape fetch], described_class.tool_names
  end

  it 'loads its system prompt from pikuri-subagents/prompts/persona-researcher.txt' do
    refute_predicate described_class.system_prompt, :empty?
    assert_match(/research sub-agent/i, described_class.system_prompt)
  end

  it 'has a step budget suited to "look it up + summarize"' do
    assert_kind_of Integer, described_class.max_steps
    assert described_class.max_steps.positive?
  end

  describe 'integration with Pikuri::Agent::Configurator#allow_agent' do
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

    it 'registers cleanly when the three bundled web tools are present' do
      configurator.add_tool(Pikuri::Tool::WEB_SEARCH)
      configurator.add_tool(Pikuri::Tool::WEB_SCRAPE)
      configurator.add_tool(Pikuri::Tool::FETCH)

      # No raise — the persona's tool_names are a subset of registered tools.
      configurator.allow_agent(Pikuri::Tool::SubAgent::RESEARCHER)
      assert_equal ['researcher'], configurator.personas.keys
    end

    it "raises the persona's tool_names check when a web tool is missing" do
      configurator.add_tool(Pikuri::Tool::WEB_SEARCH)
      # web_scrape and fetch deliberately missing

      err = assert_raises(ArgumentError) do
        configurator.allow_agent(Pikuri::Tool::SubAgent::RESEARCHER)
      end
      assert_match(/web_scrape/, err.message)
      assert_match(/fetch/, err.message)
    end
  end
end
