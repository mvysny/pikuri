# frozen_string_literal: true

require 'json'
require 'faraday'

module Pikuri
  # Test support: run the **real** {Pikuri::Agent} (real +run_loop+, real
  # listeners, real tools/extensions, real +Event+ stream, real ruby_llm loop)
  # against a **scripted HTTP backend** — no server, no network, no mock agent.
  #
  # Not loaded by default: +require 'pikuri/testing'+ from a spec. It lives off
  # the production load path (the core Zeitwerk loader ignores it).
  #
  # == How it works
  #
  # {.fake_transport} returns an ordinary {Agent::ChatTransport} whose
  # +faraday_adapter+ is an anonymous +Faraday::Adapter+ serving the responses
  # you scripted. Because {Agent#build_context} installs that adapter on the
  # agent's *per-chat* +RubyLLM::Context+ (never the global +RubyLLM.config+),
  # ruby_llm's own loop runs for real — it parses tool calls, invokes your real
  # registered tools, appends observations, and re-requests — and each scripted
  # entry is the model's next turn. No hand-rolled agent loop, nothing to drift
  # against a ruby_llm upgrade.
  #
  #   require 'pikuri/testing'
  #
  #   transport = Pikuri::Testing.fake_transport do |llm|
  #     llm.tool_call('calculator', expression: '2 + 2') # turn 1: call a real tool
  #     llm.reply('The answer is 4.')                     # turn 2: final answer
  #   end
  #
  #   agent = Pikuri::Agent.new(transport:, system_prompt: 'test') do |c|
  #     c.add_listener capture
  #     c.add_tool Pikuri::Tool::CALCULATOR
  #   end
  #   agent.run_loop(user_message: 'What is 2 + 2?')
  #   # the real loop ran the real calculator; capture saw ToolCall/ToolResult/Assistant
  #
  # == Limitations
  #
  # A fake transport feeds **one ordered response list**. Propagation to
  # sub-agents works (they derive their transport via
  # +parent.transport.with(...)+, and +Data#with+ preserves the adapter), but
  # they *share* that one list — fine for a single linear script, not for
  # targeting a specific sub-agent's replies. Per-sub-agent scripting is a
  # future upgrade (dispatch by model id / distinct fake +api_base+).
  # Only the LLM is faked: MCP servers are not, so a fake-backed spec leaves
  # the MCP registry empty, or an agent wiring +Pikuri::Mcp+ spawns the real
  # servers it configures.
  #
  # == Streaming
  #
  # One script drives a plain agent and a +streaming: true+ one alike: each
  # verb queues a {Completion}, rendered only when served — a JSON body to a
  # plain request, SSE chunks to a streamed one (a tool call's arguments in
  # fragments, as a server sends them). {Script#stream} only adds the choice of
  # where the text splits.
  module Testing
    # Build a fake transport from a scripted conversation. Pass a block that
    # calls {Script} verbs in the order the model should "reply"; each verb
    # queues one HTTP response.
    #
    # @example a two-turn tool loop
    #   Pikuri::Testing.fake_transport do |llm|
    #     llm.tool_call('calculator', expression: '2 + 2')
    #     llm.reply('The answer is 4.')
    #   end
    #
    # @param model [String] model id the fake reports (any string; the fake
    #   server "knows" it)
    # @param context_window [Integer] baked onto the transport as its stated
    #   cap, so {Agent#context_window_cap} is known from construction. With
    #   +modalities+ also stated, the +/props+ probe is skipped; otherwise it
    #   dials for real, since the scripted adapter serves only the chat, and
    #   against the default +.invalid+ host fails fast and degrades to +nil+.
    # @param modalities [Hash{Symbol => Boolean}, nil] baked onto the transport
    #   as stated, like +context_window+; the default +{}+ refuses nothing.
    #   +nil+ leaves it to the probe.
    # @param api_base [String] the transport's base URL. Never dialed (the
    #   adapter answers), but a host may key display/config off it — pass the
    #   base of the connection this fake impersonates so a UI resolves its name.
    # @param gate [Gate, nil] a latch to hold turns open mid-flight. When
    #   engaged ({Gate#block!}), the adapter parks before serving each response
    #   until {Gate#release!} — so a test can observe spinner / queued-injection
    #   / Ctrl+C paths through the real turn lifecycle. Default +nil+ (no gating).
    # @param params [Hash{String, Symbol => Object}] extra payload keys this
    #   fake connection carries; they reach the request body the scripted
    #   adapter is handed
    # @yieldparam script [Script] the conversation builder
    # @return [Agent::ChatTransport] carrying the scripted adapter; pass it as
    #   +Agent.new(transport:)+
    def self.fake_transport(model: 'fake-model', context_window: 8192, modalities: {},
                            api_base: 'http://fake.invalid/v1', gate: nil, params: {})
      script = Script.new
      yield script if block_given?
      Agent::ChatTransport.new(
        model: model,
        provider: :openai,
        assume_model_exists: true,
        # Never dialed (the adapter answers); it is the transport's identity to
        # a host, and the +api_base+ an +around_request+ hook is handed.
        api_base: api_base,
        api_key: 'not-needed',
        context_window: context_window,
        modalities: modalities,
        faraday_adapter: build_adapter(script.responses, gate),
        params: params
      )
    end

    # An anonymous +Faraday::Adapter+ subclass that serves +responses+ in order,
    # one per HTTP request. Closes over the (mutable) list, so the queue drains
    # across the several requests of one conversation regardless of how Faraday
    # reuses adapter instances.
    #
    # @param responses [Array<Completion>] as {Script} queues them
    # @param gate [Gate, nil] awaited before each response when non-nil
    # @return [Class] a +Faraday::Adapter+ subclass
    def self.build_adapter(responses, gate = nil)
      queue = responses # captured by reference; #call shifts from it
      Class.new(Faraday::Adapter) do
        # +define_method+ (not +def+) so the body closes over +queue+/+gate+;
        # +super+ must be explicit here (implicit super is illegal in a
        # define_method).
        define_method(:call) do |env|
          super(env) # base builds env.response; skipping it → "finish for nil"
          gate&.await # park here while the test holds the turn open
          completion = queue.shift or raise "Pikuri::Testing: no scripted response left for #{env.url}"

          if env.request.stream_response? # ruby_llm set req.options.on_data
            # v2 on_data routes to the chunk handler only at status 200; set it
            # before feeding, mirroring how a real adapter reads the status line
            # ahead of the body.
            env.status = 200
            on_data = env.request.on_data
            size = 0
            completion.to_sse.each do |chunk|
              size += chunk.bytesize
              on_data.call(chunk, size, env)
            end
            save_response(env, 200, '', { 'Content-Type' => 'text/event-stream' }, nil)
          else
            save_response(env, 200, JSON.generate(completion.to_json_body),
                          { 'Content-Type' => 'application/json' }, nil)
          end
          @app.call(env)
        end
      end
    end

    # Collects the scripted conversation: each verb queues one {Completion} on
    # {#responses}, in call order. You don't build these directly —
    # {Testing.fake_transport} yields one to your block.
    #
    #   fake_transport do |llm|
    #     llm.reply('hi')                                  # plain answer
    #     llm.tool_call('calculator', expression: '2+2')   # a tool turn
    #     llm.stream('The ', 'answer ', 'is ', '4.')       # an answer in chosen deltas
    #   end
    class Script
      # @return [Array<Completion>] queued completions in call order
      attr_reader :responses

      def initialize
        @responses = []
        @tool_call_seq = 0
      end

      # Queue a plain assistant-text turn (the model's final answer for that
      # step). A streaming agent gets it as a single delta.
      #
      # @param text [String] the assistant message content
      # @return [self]
      def reply(text)
        stream(text)
      end

      # Queue an assistant turn that calls one tool. The real ruby_llm loop
      # parses it, runs the real registered tool, appends the observation, and
      # re-requests — so the *next* queued entry is the model's follow-up.
      #
      # @example
      #   llm.tool_call('calculator', expression: '2 + 2')
      #
      # @param name [String] registered tool name (e.g. +"calculator"+)
      # @param arguments [Hash{Symbol => Object}] tool arguments, JSON-encoded
      #   into the wire call
      # @return [self]
      def tool_call(name, **arguments)
        tool_batch([name, arguments])
      end

      # Queue an assistant turn that calls several tools at once — one
      # +tool_calls+ array, the shape a provider sends when the model batches.
      # ruby_llm runs them in order, each answered by its own +:tool+ message.
      #
      #   llm.tool_batch(['calculator', { expression: '1 + 1' }],
      #                  ['calculator', { expression: '2 + 2' }])
      #
      # What a spec needs to exercise anything treating a batch as a unit — the
      # interloper's drain boundary, or which call a mid-batch unwind blames.
      #
      # @param calls [Array<Array(String, Hash)>] +[name, arguments]+ pairs, in
      #   the order the model asked for them
      # @return [self]
      def tool_batch(*calls)
        tool_calls = calls.map do |name, arguments|
          @tool_call_seq += 1
          Completion::ToolCall.new(id: "call_#{@tool_call_seq}", name: name,
                                   arguments: JSON.generate(arguments || {}))
        end
        @responses << Completion.new(deltas: [], tool_calls: tool_calls)
        self
      end

      # {#reply} with the text split where you choose: a +streaming: true+
      # agent emits one {Agent::Event::AssistantDelta} per +delta+, then the
      # assembled {Agent::Event::Assistant}. A plain agent gets them joined.
      #
      # @example
      #   llm.stream('The ', 'answer ', 'is ', '4.')
      #
      # @param deltas [Array<String>] content fragments, streamed in order
      # @return [self]
      def stream(*deltas)
        @responses << Completion.new(deltas: deltas, tool_calls: [])
        self
      end
    end

    # One scripted assistant turn, rendered to the wire as whichever shape the
    # request asked for.
    #
    #   c = Completion.new(deltas: ['The ', 'answer.'], tool_calls: [])
    #   c.to_json_body   # => {"choices" => [{"message" => {"content" => "The answer.", ...}}], ...}
    #   c.to_sse         # => ["data: {...\"content\":\"The \"...}\n\n", ..., "data: [DONE]\n\n"]
    #
    # Immutable.
    Completion = Data.define(:deltas, :tool_calls) do
      # @!attribute [r] deltas
      #   @return [Array<String>] the text, in the fragments it streams as;
      #     empty for a tool-only turn
      # @!attribute [r] tool_calls
      #   @return [Array<Completion::ToolCall>] in the order the model asked

      # @return [Hash{String => Object}] the OpenAI chat-completion body
      def to_json_body
        message = { 'role' => 'assistant', 'content' => deltas.empty? ? nil : deltas.join }
        unless tool_calls.empty?
          message['tool_calls'] = tool_calls.map do |call|
            { 'id' => call.id, 'type' => 'function',
              'function' => { 'name' => call.name, 'arguments' => call.arguments } }
          end
        end
        { 'model' => 'fake', 'choices' => [{ 'message' => message }], 'usage' => usage }
      end

      # The SSE events a server streams. Each tool call goes out the way a
      # server sends it: +id+ and +name+ first, then its JSON arguments in two
      # fragments keyed only by +index+, which ruby_llm's own accumulator
      # joins back together.
      #
      # @return [Array<String>] one +data:+ event per element, +[DONE]+ last
      def to_sse
        text = deltas.map { |d| { 'content' => d } }
        calls = tool_calls.each_with_index.flat_map do |call, index|
          half = call.arguments.length / 2
          [{ 'index' => index, 'id' => call.id, 'type' => 'function',
             'function' => { 'name' => call.name, 'arguments' => '' } },
           { 'index' => index, 'function' => { 'arguments' => call.arguments[0...half] } },
           { 'index' => index, 'function' => { 'arguments' => call.arguments[half..] } }]
        end.map { |fragment| { 'tool_calls' => [fragment] } }
        last = { 'delta' => {} }
        last['finish_reason'] = 'tool_calls' unless tool_calls.empty?
        (text + calls).map { |delta| sse_data('choices' => [{ 'delta' => delta }]) } +
          [sse_data('choices' => [last], 'usage' => usage), "data: [DONE]\n\n"]
      end

      private

      # @param body [Hash{String => Object}] one streamed chunk, less its +model+
      # @return [String] its SSE event
      def sse_data(body)
        "data: #{JSON.generate({ 'model' => 'fake' }.merge(body))}\n\n"
      end

      # Nominal token counts so a {Agent::Event::Tokens} still fires.
      #
      # @return [Hash{String => Integer}]
      def usage
        { 'prompt_tokens' => 10, 'completion_tokens' => 5, 'total_tokens' => 15 }
      end
    end

    # One tool call of a {Completion}.
    #
    # @!attribute [r] id
    #   @return [String] e.g. +"call_1"+, numbered across the whole script
    # @!attribute [r] name
    #   @return [String] the registered tool name
    # @!attribute [r] arguments
    #   @return [String] the arguments, already JSON-encoded
    Completion::ToolCall = Data.define(:id, :name, :arguments)

    # A latch that holds a fake turn open mid-flight. Pass one to
    # {Testing.fake_transport}; the adapter parks (inside the HTTP call, on the
    # agent's worker thread) at every response while the gate is engaged, so a
    # test can observe the turn-in-progress state — spinner, queued injections,
    # a Ctrl+C landing mid-turn — then let it finish.
    #
    #   gate = Pikuri::Testing::Gate.new
    #   transport = Pikuri::Testing.fake_transport(gate:) { |llm| llm.stream('done') }
    #   gate.block!
    #   session.submit('work')          # the real turn parks in the adapter
    #   # ... assert spinner / press Ctrl+C ...
    #   gate.release!                    # the turn proceeds and completes
    #
    # A test that engages the gate is responsible for releasing it —
    # {#await} blocks with no timeout, mirroring the old stubs' +Queue#pop+.
    #
    # Thread-safe.
    class Gate
      def initialize
        @mutex = Mutex.new
        @cv = ConditionVariable.new
        @blocked = false
      end

      # Engage the latch: the *next* (and every subsequent) response parks in
      # {#await} until {#release!}.
      #
      # @return [void]
      def block!
        @mutex.synchronize { @blocked = true }
        nil
      end

      # Disengage the latch and wake every parked response.
      #
      # @return [void]
      def release!
        @mutex.synchronize do
          @blocked = false
          @cv.broadcast
        end
        nil
      end

      # Block the calling thread while the latch is engaged. Called by the
      # adapter before serving each response; a no-op when not blocked.
      #
      # @return [void]
      def await
        @mutex.synchronize { @cv.wait(@mutex) while @blocked }
        nil
      end
    end
  end
end
