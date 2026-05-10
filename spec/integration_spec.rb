# frozen_string_literal: true

require 'json'
require 'faraday'
require 'faraday/adapter/test'

# End-to-end happy path: drive a real +RubyLLM::Chat#ask+ through ruby_llm's
# OpenAI provider, intercepting the HTTP call at Faraday's adapter layer to
# return canned responses. Pinned here as the load-bearing test for
# {Tool#to_ruby_llm_tool} — it's the one place that exercises ruby_llm's
# full request-serialization, response-parsing, and tool-dispatch pipeline
# against the synthetic +RubyLLM::Tool+ subclass our adapter produces. If
# ruby_llm's tool DSL ever shifts (how +params(hash)+ accepts a raw schema,
# the keyrest bypass on +validate_keyword_arguments+, how +execute+ is
# invoked), this is what catches the regression before any real LLM does.
RSpec.describe 'Agent end-to-end tool dispatch' do
  let(:test_stubs) { Faraday::Adapter::Test::Stubs.new }

  # Whatever the first turn does, the second turn always returns this; the
  # spec asserts we reach it, which proves ruby_llm fed the tool result back
  # in and completed the loop.
  let(:final_assistant_text) { 'Echoed back: hi' }

  # Whatever turn-1 tool-call we want ruby_llm to dispatch.
  let(:tool_call_id)        { 'call_abc' }
  let(:tool_call_name)      { 'echo' }
  let(:tool_call_arguments) { { 'text' => 'hi' } }

  before do
    @captured_requests = []
    captured = @captured_requests

    # Two-turn dispatcher. Turn 1 (no tool-role messages yet) returns a
    # tool_calls response that drives ruby_llm to invoke our tool. Turn 2
    # (the tool result is now in the message history) returns final text,
    # which ends the loop.
    test_stubs.post('/v1/chat/completions') do |env|
      body = JSON.parse(env.body)
      captured << body
      response = body['messages'].any? { |m| m['role'] == 'tool' } ? final_response : tool_call_response
      [200, { 'Content-Type' => 'application/json' }, JSON.generate(response)]
    end

    stubs = test_stubs
    @original_faraday_new = Faraday.method(:new)
    original = @original_faraday_new
    Faraday.define_singleton_method(:new) do |*args, **kwargs, &user_block|
      original.call(*args, **kwargs) do |faraday|
        user_block&.call(faraday)
        # Override whatever adapter ruby_llm installed (:net_http) with the
        # Faraday test adapter. Faraday's RackBuilder tracks @adapter as a
        # single slot, so calling +adapter+ again just replaces it.
        faraday.adapter :test, stubs
      end
    end

    # Pikuri's bin/pikuri does this for the local llama.cpp server; the spec
    # has to do the same so RubyLLM::Connection#ensure_configured! is happy.
    RubyLLM.configure do |c|
      c.openai_api_base = 'https://example.test/v1'
      c.openai_api_key  = 'test-key'
    end

    @original_md_parse = TTY::Markdown.method(:parse)
    TTY::Markdown.define_singleton_method(:parse) { |text, **| text }
  end

  after do
    original = @original_faraday_new
    Faraday.define_singleton_method(:new) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) }

    md_original = @original_md_parse
    TTY::Markdown.define_singleton_method(:parse) { |*args, **kwargs| md_original.call(*args, **kwargs) }
  end

  # Plain text turn-2 response: assistant content, no tool calls.
  let(:final_response) do
    {
      'id'     => 'cmpl-2',
      'model'  => 'test-model',
      'object' => 'chat.completion',
      'choices' => [
        { 'index' => 0,
          'message' => { 'role' => 'assistant', 'content' => final_assistant_text },
          'finish_reason' => 'stop' }
      ],
      'usage' => { 'prompt_tokens' => 20, 'completion_tokens' => 5, 'total_tokens' => 25 }
    }
  end

  # Turn-1 response: assistant emits a tool call against our test tool.
  let(:tool_call_response) do
    {
      'id'     => 'cmpl-1',
      'model'  => 'test-model',
      'object' => 'chat.completion',
      'choices' => [
        { 'index' => 0,
          'message' => {
            'role'    => 'assistant',
            'content' => nil,
            'tool_calls' => [
              { 'id'   => tool_call_id,
                'type' => 'function',
                'function' => { 'name' => tool_call_name,
                                'arguments' => JSON.generate(tool_call_arguments) } }
            ]
          },
          'finish_reason' => 'tool_calls' }
      ],
      'usage' => { 'prompt_tokens' => 10, 'completion_tokens' => 4, 'total_tokens' => 14 }
    }
  end

  it 'wires a Tool through ruby_llm: tool advertised, dispatched, result fed back, final text returned' do
    received_args = nil
    echo_tool = Tool.new(
      name: 'echo',
      description: 'Echoes its input.',
      parameters: Tool::Parameters.build { |p| p.required_string :text, 'Text to echo.' },
      execute: lambda { |text:|
        received_args = { text: text }
        "echo: #{text}"
      }
    )

    agent = Agent.new(
      model: 'test-model',
      provider: :openai,
      assume_model_exists: true,
      system_prompt: 'be terse',
      tools: [echo_tool]
    )

    # Silence the listener output so the spec doesn't pollute test output.
    capture_stdout { agent.run_loop(user_message: 'please echo hi') }

    # Two HTTP turns happened.
    assert_equal 2, @captured_requests.size, 'expected exactly two completion calls'

    # Turn 1 advertised our tool in OpenAI's function-calling shape.
    turn1 = @captured_requests[0]
    assert_equal 1, turn1['tools'].size
    advertised = turn1['tools'][0]
    assert_equal 'function', advertised['type']
    assert_equal 'echo', advertised['function']['name']
    assert_equal 'Echoes its input.', advertised['function']['description']
    schema = advertised['function']['parameters']
    assert_equal 'object', schema['type']
    assert_equal 'string', schema['properties']['text']['type']
    assert_equal ['text'], schema['required']

    # ruby_llm dispatched the tool: pikuri's execute Proc actually ran with
    # the validated args from the LLM's tool_call.arguments JSON.
    assert_equal({ text: 'hi' }, received_args)

    # Turn 2 fed the observation back to the LLM as a tool-role message
    # bound to the original tool_call id.
    turn2 = @captured_requests[1]
    tool_msg = turn2['messages'].find { |m| m['role'] == 'tool' }
    refute_nil tool_msg, 'expected a tool-role message in the second request'
    assert_equal tool_call_id, tool_msg['tool_call_id']
    assert_equal 'echo: hi', tool_msg['content']

    # And the loop terminated on turn-2's plain text, which is what the
    # caller sees as the final assistant message.
    assert_equal final_assistant_text, agent.last_assistant_content
  end

  # Focused on the description channel: tool-level description and per-
  # parameter descriptions are the strings the LLM actually reads to
  # decide whether to call a tool and how to fill its arguments. If
  # +Tool::Parameters#to_h+ ever drops +description+ from a property, or
  # if ruby_llm's +params(hash)+ filters them out, the model will start
  # calling tools with garbage arguments — but every other check (types,
  # required, dispatch) keeps passing. This test pins the wire shape.
  it 'propagates tool and parameter descriptions onto the OpenAI request' do
    described_tool = Tool.new(
      name: tool_call_name,
      description: 'Echoes its input verbatim — useful when the user asks to repeat text.',
      parameters: Tool::Parameters.build do |p|
        p.required_string :text, 'The exact text the assistant should echo back.'
        p.optional_integer :repeat, 'Number of times to repeat the echo (default 1).'
      end,
      execute: ->(text:, repeat: 1) { (["echo: #{text}"] * repeat).join("\n") }
    )

    agent = Agent.new(
      model: 'test-model',
      provider: :openai,
      assume_model_exists: true,
      system_prompt: 'be terse',
      tools: [described_tool]
    )

    capture_stdout { agent.run_loop(user_message: 'please echo hi') }

    advertised = @captured_requests[0]['tools'][0]
    assert_equal 'Echoes its input verbatim — useful when the user asks to repeat text.',
                 advertised['function']['description']

    properties = advertised['function']['parameters']['properties']
    assert_equal 'The exact text the assistant should echo back.',
                 properties['text']['description']
    assert_equal 'Number of times to repeat the echo (default 1).',
                 properties['repeat']['description']
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end
end
