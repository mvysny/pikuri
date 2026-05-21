# frozen_string_literal: true

require 'set'

# Integration spec — exercises the real +mcp+ gem against the
# in-tree test server at +spec/support/test_mcp_server.rb+. The test
# server speaks real MCP over stdio, so this suite catches anything
# the schema-adapter or subprocess lifecycle would get wrong against
# a real server, without needing +npx+ or network egress.
#
# Each spec spawns its own +McpServers+ so a server crash / close in
# one example can't leak into the next.
RSpec.describe Pikuri::McpServers do
  TEST_SERVER_COMMAND = ['bundle', 'exec', 'ruby', File.expand_path('../support/test_mcp_server.rb', __dir__)].freeze

  def fresh_registry
    Pikuri::McpRegistry.new(entries: [
      Pikuri::McpRegistry::StdioEntry.new(id: 'test', command: TEST_SERVER_COMMAND)
    ])
  end

  def fake_agent
    # Stand-in agent that records tools added via +internal_add_tool+
    # without instantiating a real +Pikuri::Agent+ (which would require
    # a RubyLLM transport).
    agent = Object.new
    added = []
    agent.define_singleton_method(:internal_add_tool) { |t| added << t }
    agent.define_singleton_method(:added_tools) { added }
    agent
  end

  describe '#initialize against the test fixture' do
    it 'spawns the server, lists tools, exposes them via live_ids' do
      servers = Pikuri::McpServers.new(fresh_registry)
      assert_equal ['test'], servers.live_ids
      refute servers.empty?
    ensure
      servers&.close
    end

    it 'logs one INFO event per started server with the raw schema' do
      captured = StringIO.new
      original = Pikuri.log_io
      Pikuri.log_io = captured
      servers = Pikuri::McpServers.new(fresh_registry)
      log = captured.string
      assert_match(/MCP server "test" started/, log)
      assert_match(/Tools \(4\)/, log)
      assert_match(/- echo$/m, log)
      assert_match(/- divide$/m, log)
      assert_match(/input_schema:/, log)
    ensure
      Pikuri.log_io = original if original
      servers&.close
    end

    it 'drops a server whose command does not exist, logs a warning, leaves live_ids empty' do
      captured = StringIO.new
      original = Pikuri.log_io
      Pikuri.log_io = captured
      bogus = Pikuri::McpRegistry.new(entries: [
        Pikuri::McpRegistry::StdioEntry.new(id: 'bogus', command: ['/nonexistent/binary/path'])
      ])
      servers = Pikuri::McpServers.new(bogus)
      assert servers.empty?
      assert_equal [], servers.live_ids
      assert_match(/Failed to start MCP server "bogus"/, captured.string)
    ensure
      Pikuri.log_io = original if original
      servers&.close
    end

    it 'drops an HttpEntry whose endpoint refuses connections, logs the url in the warning' do
      # Port 1 on loopback is reliably refused-connect — fails fast,
      # mirrors the bogus-stdio test for the HTTP transport path. Real
      # call into MCP::Client::HTTP, so this exercises build_transport
      # dispatch + the rescue + describe_entry url branch.
      captured = StringIO.new
      original = Pikuri.log_io
      Pikuri.log_io = captured
      bogus = Pikuri::McpRegistry.new(entries: [
        Pikuri::McpRegistry::HttpEntry.new(id: 'bogus-http', url: 'http://127.0.0.1:1/mcp')
      ])
      servers = Pikuri::McpServers.new(bogus)
      assert servers.empty?
      assert_equal [], servers.live_ids
      assert_match(/Failed to start MCP server "bogus-http"/, captured.string)
      assert_match(%r{url: http://127\.0\.0\.1:1/mcp}, captured.string)
    ensure
      Pikuri.log_io = original if original
      servers&.close
    end

    it 'still constructs (empty) when the registry itself is empty' do
      servers = Pikuri::McpServers.new(Pikuri::McpRegistry::EMPTY)
      assert servers.empty?
      assert_equal '', servers.system_prompt_snippet
    ensure
      servers&.close
    end
  end

  describe '#system_prompt_snippet' do
    it 'renders an <available_mcps> block listing live servers + descriptions' do
      servers = Pikuri::McpServers.new(fresh_registry)
      snippet = servers.system_prompt_snippet
      assert_match(/<available_mcps>/, snippet)
      assert_match(%r{<id>test</id>}, snippet)
      assert_match(/In-tree fixture used by pikuri specs/, snippet)
      assert_match(%r{</available_mcps>}, snippet)
    ensure
      servers&.close
    end

    it 'returns empty string when no servers are live' do
      servers = Pikuri::McpServers.new(Pikuri::McpRegistry::EMPTY)
      assert_equal '', servers.system_prompt_snippet
    ensure
      servers&.close
    end
  end

  describe '#register_tools_with_agent' do
    it 'adds one RubyLLM::Tool subclass per MCP-exposed tool to the agent' do
      servers = Pikuri::McpServers.new(fresh_registry)
      agent = fake_agent
      count = servers.register_tools_with_agent('test', agent)
      assert_equal 4, count
      assert_equal 4, agent.added_tools.size
      assert(agent.added_tools.all? { |t| t < RubyLLM::Tool })
    ensure
      servers&.close
    end

    it 'namespaces tool names as <server_id>__<tool_name>' do
      servers = Pikuri::McpServers.new(fresh_registry)
      agent = fake_agent
      servers.register_tools_with_agent('test', agent)
      names = agent.added_tools.map(&:name)
      assert_includes names, 'test__echo'
      assert_includes names, 'test__divide'
      assert_includes names, 'test__crash'
    ensure
      servers&.close
    end

    it 'prefixes every tool description with the provenance marker' do
      servers = Pikuri::McpServers.new(fresh_registry)
      agent = fake_agent
      servers.register_tools_with_agent('test', agent)
      agent.added_tools.each do |t|
        # RubyLLM::Tool stashes the description on the class.
        desc = t.respond_to?(:description) ? t.description : t.instance_variable_get(:@description)
        assert_match(/\A\[From MCP server "test"\]/, desc.to_s)
      end
    ensure
      servers&.close
    end

    it 'preserves the MCP tool description verbatim after the provenance prefix' do
      servers = Pikuri::McpServers.new(fresh_registry)
      agent = fake_agent
      servers.register_tools_with_agent('test', agent)
      echo = agent.added_tools.find { |t| t.name == 'test__echo' }
      assert_equal(
        %([From MCP server "test"]\n\nEchoes the given message back to the caller.),
        echo.description
      )
    ensure
      servers&.close
    end

    it 'propagates input-parameter descriptions to the RubyLLM wire schema' do
      # RubyLLM::Tool#params_schema is the JSON Schema that ships to
      # the provider for tool calling. Asserting against it directly
      # verifies that per-property descriptions from the MCP server's
      # input_schema make it all the way through deep_dup +
      # stringify_keys without being dropped.
      servers = Pikuri::McpServers.new(fresh_registry)
      agent = fake_agent
      servers.register_tools_with_agent('test', agent)

      echo = agent.added_tools.find { |t| t.name == 'test__echo' }
      schema = echo.new.params_schema
      assert_equal 'object', schema['type']
      assert_includes schema['required'], 'message'
      assert_equal 'The message to echo back verbatim.',
                   schema.dig('properties', 'message', 'description')
      assert_equal 'string',
                   schema.dig('properties', 'message', 'type')

      divide = agent.added_tools.find { |t| t.name == 'test__divide' }
      div_schema = divide.new.params_schema
      assert_equal 'The numerator.',
                   div_schema.dig('properties', 'a', 'description')
      assert_equal 'The denominator. Must be non-zero.',
                   div_schema.dig('properties', 'b', 'description')
    ensure
      servers&.close
    end

    it 'strips the $schema URI to avoid provider-side rejection of extra top-level keys' do
      servers = Pikuri::McpServers.new(fresh_registry)
      agent = fake_agent
      servers.register_tools_with_agent('test', agent)
      echo = agent.added_tools.find { |t| t.name == 'test__echo' }
      schema = echo.new.params_schema
      refute schema.key?('$schema'), "expected $schema URI to be stripped, got: #{schema.inspect}"
    ensure
      servers&.close
    end

    it 'logs output_schema in the audit log when the MCP server declares one' do
      # output_schema has no destination in RubyLLM's Tool surface
      # (no return-schema slot), so the audit log is the only place
      # it survives. The test fixture's `echo` tool declares one;
      # asserting it shows up confirms we don't quietly drop it.
      captured = StringIO.new
      original = Pikuri.log_io
      Pikuri.log_io = captured
      servers = Pikuri::McpServers.new(fresh_registry)
      log = captured.string
      assert_match(/output_schema:.*echoed/, log)
    ensure
      Pikuri.log_io = original if original
      servers&.close
    end

    it 'raises ArgumentError for an unknown id (loud-on-bugs, not Error: ...)' do
      servers = Pikuri::McpServers.new(fresh_registry)
      assert_raises(ArgumentError) do
        servers.register_tools_with_agent('nope', fake_agent)
      end
    ensure
      servers&.close
    end
  end

  describe 'synthesized RubyLLM::Tool execute paths' do
    it 'returns the raw text content on success' do
      servers = Pikuri::McpServers.new(fresh_registry)
      agent = fake_agent
      servers.register_tools_with_agent('test', agent)
      echo = agent.added_tools.find { |t| t.name == 'test__echo' }
      assert_equal 'hello pikuri', echo.new.execute(message: 'hello pikuri')
    ensure
      servers&.close
    end

    it 'converts MCP-side tool errors into Error: ... observations' do
      servers = Pikuri::McpServers.new(fresh_registry)
      agent = fake_agent
      servers.register_tools_with_agent('test', agent)
      divide = agent.added_tools.find { |t| t.name == 'test__divide' }
      result = divide.new.execute(a: 10, b: 0)
      assert_match(/\AError:/, result)
      assert_match(/division by zero/, result)
    ensure
      servers&.close
    end

    it 'surfaces mid-call server death as an Error: ... observation' do
      servers = Pikuri::McpServers.new(fresh_registry)
      agent = fake_agent
      servers.register_tools_with_agent('test', agent)
      crash = agent.added_tools.find { |t| t.name == 'test__crash' }
      result = crash.new.execute
      assert_match(/\AError: MCP server "test" call failed/, result)
    ensure
      servers&.close
    end
  end

  describe '#view_for_sub_agent' do
    it 'returns a View that delegates live_ids and snippet to the root' do
      servers = Pikuri::McpServers.new(fresh_registry)
      view = servers.view_for_sub_agent
      assert_kind_of Pikuri::McpServers::View, view
      assert_equal servers.live_ids, view.live_ids
      assert_equal servers.system_prompt_snippet, view.system_prompt_snippet
    ensure
      servers&.close
    end

    it 'delegates register_tools_with_agent to the root (shared clients, no re-spawn)' do
      servers = Pikuri::McpServers.new(fresh_registry)
      view = servers.view_for_sub_agent
      agent = fake_agent
      count = view.register_tools_with_agent('test', agent)
      assert_equal 4, count
      assert_equal 4, agent.added_tools.size
    ensure
      servers&.close
    end

    it 'returns self when called on a View (nested sub-agents share the same view)' do
      servers = Pikuri::McpServers.new(fresh_registry)
      view = servers.view_for_sub_agent
      assert_same view, view.view_for_sub_agent
    ensure
      servers&.close
    end
  end

  describe Pikuri::McpServers::McpConnect do
    it 'returns an Error: ... for an unknown id' do
      servers = Pikuri::McpServers.new(fresh_registry)
      agent = fake_agent
      tool = servers.build_mcp_connect_tool(agent)
      result = tool.run('id' => 'unknown')
      assert_match(/\AError: unknown MCP server id/, result)
      assert_match(/Available: test/, result)
    ensure
      servers&.close
    end

    it 'connects an unknown-to-this-instance server and reports the tool count' do
      servers = Pikuri::McpServers.new(fresh_registry)
      agent = fake_agent
      tool = servers.build_mcp_connect_tool(agent)
      result = tool.run('id' => 'test')
      assert_match(/Connected to MCP server 'test'/, result)
      assert_match(/Added 4 tools/, result)
      assert_equal 4, agent.added_tools.size
    ensure
      servers&.close
    end

    it 'rejects re-activation with an Error: ... (and does not re-register tools)' do
      servers = Pikuri::McpServers.new(fresh_registry)
      agent = fake_agent
      tool = servers.build_mcp_connect_tool(agent)
      tool.run('id' => 'test')
      result = tool.run('id' => 'test')
      assert_match(/\AError: server 'test' is already connected/, result)
      assert_equal 4, agent.added_tools.size # not 8
    ensure
      servers&.close
    end

    it 'tracks activation per-instance — a fresh McpConnect can reactivate' do
      servers = Pikuri::McpServers.new(fresh_registry)
      agent1 = fake_agent
      agent2 = fake_agent
      tool1 = servers.build_mcp_connect_tool(agent1)
      tool2 = servers.build_mcp_connect_tool(agent2)
      tool1.run('id' => 'test')
      result2 = tool2.run('id' => 'test') # fresh activation set
      assert_match(/Connected to MCP server 'test'/, result2)
      assert_equal 4, agent1.added_tools.size
      assert_equal 4, agent2.added_tools.size
    ensure
      servers&.close
    end
  end

  describe '#close' do
    it 'is idempotent' do
      servers = Pikuri::McpServers.new(fresh_registry)
      servers.close
      # second call must not raise
      servers.close
    end
  end

  # Synthesis-path tests use the fixture with +PIKURI_TEST_SKIP_INSTRUCTIONS=1+
  # so the server's +initialize+ handshake omits the +instructions+ field
  # — that's the real-world common case where the fallback chain in
  # +#resolve_description+ would otherwise bottom out at +serverInfo.name+.
  describe 'description synthesis via thinker:' do
    def no_instructions_registry
      cmd = ['env', 'PIKURI_TEST_SKIP_INSTRUCTIONS=1', *TEST_SERVER_COMMAND]
      Pikuri::McpRegistry.new(entries: [
        Pikuri::McpRegistry::StdioEntry.new(id: 'test', command: cmd)
      ])
    end

    it 'invokes the thinker with a prompt containing every tool name + description, uses the result as the description' do
      received_prompt = nil
      thinker = lambda do |prompt|
        received_prompt = prompt
        'Provides four demo tools used by pikuri specs to exercise MCP wiring.'
      end
      servers = Pikuri::McpServers.new(no_instructions_registry, thinker: thinker)
      assert_match(/Tools:/, received_prompt)
      assert_match(/- echo: /, received_prompt)
      assert_match(/- divide: /, received_prompt)
      assert_match(/- slow: /, received_prompt)
      assert_match(/- crash: /, received_prompt)
      assert_match(/four demo tools/, servers.system_prompt_snippet)
    ensure
      servers&.close
    end

    it 'collapses multi-line / surrounding-whitespace synthesizer output into a single line' do
      thinker = ->(_p) { "\n  multi\n  line\n  result\n  " }
      servers = Pikuri::McpServers.new(no_instructions_registry, thinker: thinker)
      desc = servers.system_prompt_snippet[/<description>(.+?)<\/description>/, 1]
      assert_equal 'multi line result', desc
    ensure
      servers&.close
    end

    it 'skips synthesis when the server already supplied instructions' do
      called = false
      thinker = ->(_p) { called = true; 'unused' }
      servers = Pikuri::McpServers.new(fresh_registry, thinker: thinker)
      refute called, 'thinker should not be called when instructions: is present'
      assert_match(/In-tree fixture used by pikuri specs/, servers.system_prompt_snippet)
    ensure
      servers&.close
    end

    it 'warns and falls back to serverInfo.name when the thinker raises StandardError' do
      captured = StringIO.new
      original = Pikuri.log_io
      Pikuri.log_io = captured
      thinker = ->(_p) { raise 'simulated synth blip' }
      servers = Pikuri::McpServers.new(no_instructions_registry, thinker: thinker)
      assert_match(/MCP description synthesis failed for "test"/, captured.string)
      assert_match(/simulated synth blip/, captured.string)
      desc = servers.system_prompt_snippet[/<description>(.+?)<\/description>/, 1]
      assert_equal 'pikuri-test-mcp', desc
    ensure
      Pikuri.log_io = original if original
      servers&.close
    end

    it 'falls back to serverInfo.name when the thinker returns blank' do
      thinker = ->(_p) { "   \n  \n" }
      servers = Pikuri::McpServers.new(no_instructions_registry, thinker: thinker)
      desc = servers.system_prompt_snippet[/<description>(.+?)<\/description>/, 1]
      assert_equal 'pikuri-test-mcp', desc
    ensure
      servers&.close
    end

    it 'propagates Cancelled out of McpServers.new without rescuing it as a synthesis failure' do
      thinker = ->(_p) { raise Pikuri::Agent::Control::Cancellable::Cancelled }
      captured = StringIO.new
      original = Pikuri.log_io
      Pikuri.log_io = captured
      assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) do
        Pikuri::McpServers.new(no_instructions_registry, thinker: thinker)
      end
      refute_match(/synthesis failed/, captured.string)
      refute_match(/Failed to start MCP server/, captured.string)
    ensure
      Pikuri.log_io = original if original
    end

    it 'logs the resolved description in the audit log so a user can see when synthesis kicked in' do
      captured = StringIO.new
      original = Pikuri.log_io
      Pikuri.log_io = captured
      thinker = ->(_p) { 'Synthesized blurb for the test fixture.' }
      servers = Pikuri::McpServers.new(no_instructions_registry, thinker: thinker)
      assert_match(/Description:\s+Synthesized blurb for the test fixture\./, captured.string)
    ensure
      Pikuri.log_io = original if original
      servers&.close
    end
  end
end
