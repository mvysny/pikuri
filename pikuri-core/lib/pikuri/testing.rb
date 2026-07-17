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
  # sub-agents / the synthesizer works (they derive their transport via
  # +parent.transport.with(...)+, and +Data#with+ preserves the adapter), but
  # they *share* that one list — fine for a single linear script, not for
  # targeting a specific sub-agent's replies. Per-sub-agent scripting is a
  # future upgrade (dispatch by model id / distinct fake +api_base+).
  # Tool-call *streaming* (fragmented +tool_calls+ deltas) is not modelled;
  # {Script#stream} streams text only.
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
    # @param context_window [Integer] baked onto the transport so
    #   {Agent#detect_and_emit_context_cap!} skips the real +/props+ HTTP probe
    # @param api_base [String] the transport's base URL. Never dialed (the
    #   adapter answers), but a host may key display/config off it — pass the
    #   base of the connection this fake impersonates so a UI resolves its name.
    # @param gate [Gate, nil] a latch to hold turns open mid-flight. When
    #   engaged ({Gate#block!}), the adapter parks before serving each response
    #   until {Gate#release!} — so a test can observe spinner / queued-injection
    #   / Ctrl+C paths through the real turn lifecycle. Default +nil+ (no gating).
    # @yieldparam script [Script] the conversation builder
    # @return [Agent::ChatTransport] carrying the scripted adapter; pass it as
    #   +Agent.new(transport:)+
    def self.fake_transport(model: 'fake-model', context_window: 8192,
                            api_base: 'http://fake.invalid/v1', gate: nil)
      script = Script.new
      yield script if block_given?
      Agent::ChatTransport.new(
        model: model,
        provider: :openai,
        assume_model_exists: true,
        # An api_base forces the connection-override path (Context#chat), the
        # only branch that honours faraday_adapter; the host is never dialed.
        api_base: api_base,
        api_key: 'not-needed',
        context_window: context_window,
        faraday_adapter: build_adapter(script.responses, gate)
      )
    end

    # An anonymous +Faraday::Adapter+ subclass that serves +responses+ in order,
    # one per HTTP request. Closes over the (mutable) list, so the queue drains
    # across the several requests of one conversation regardless of how Faraday
    # reuses adapter instances.
    #
    # @param responses [Array<Hash>] entries shaped +{json: Hash}+ (non-stream)
    #   or +{sse: Array<String>}+ (stream), as {Script} produces
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
          entry = queue.shift or raise "Pikuri::Testing: no scripted response left for #{env.url}"

          if env.request.stream_response? # ruby_llm set req.options.on_data
            # v2 on_data routes to the chunk handler only at status 200; set it
            # before feeding, mirroring how a real adapter reads the status line
            # ahead of the body.
            env.status = 200
            on_data = env.request.on_data
            size = 0
            entry.fetch(:sse).each do |chunk|
              size += chunk.bytesize
              on_data.call(chunk, size, env)
            end
            save_response(env, 200, '', { 'Content-Type' => 'text/event-stream' }, nil)
          else
            save_response(env, 200, JSON.generate(entry.fetch(:json)),
                          { 'Content-Type' => 'application/json' }, nil)
          end
          @app.call(env)
        end
      end
    end

    # Collects the scripted conversation: each verb appends one OpenAI-wire
    # response body to {#responses}, in call order. You don't build these
    # directly — {Testing.fake_transport} yields one to your block.
    #
    #   fake_transport do |llm|
    #     llm.reply('hi')                                  # plain answer
    #     llm.tool_call('calculator', expression: '2+2')   # a tool turn
    #     llm.stream('The ', 'answer ', 'is ', '4.')       # a streamed answer
    #   end
    class Script
      # @return [Array<Hash>] queued response entries in call order
      attr_reader :responses

      def initialize
        @responses = []
        @tool_call_seq = 0
      end

      # Queue a plain assistant-text turn (the model's final answer for that
      # step).
      #
      # @param text [String] the assistant message content
      # @return [self]
      def reply(text)
        @responses << { json: assistant_body(content: text) }
        self
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
        @tool_call_seq += 1
        call = {
          'id' => "call_#{@tool_call_seq}",
          'type' => 'function',
          'function' => { 'name' => name, 'arguments' => JSON.generate(arguments) }
        }
        @responses << { json: assistant_body(content: nil, tool_calls: [call]) }
        self
      end

      # Queue a *streamed* assistant-text turn: each +delta+ becomes one SSE
      # chunk, so a +streaming: true+ agent emits a matching sequence of
      # {Agent::Event::AssistantDelta}s and a final assembled
      # {Agent::Event::Assistant}. Text only — tool-call streaming is not
      # modelled.
      #
      # @example
      #   llm.stream('The ', 'answer ', 'is ', '4.')
      #
      # @param deltas [Array<String>] content fragments, streamed in order
      # @return [self]
      def stream(*deltas)
        chunks = deltas.map do |d|
          "data: #{JSON.generate('model' => 'fake', 'choices' => [{ 'delta' => { 'content' => d } }])}\n\n"
        end
        chunks << "data: #{JSON.generate('model' => 'fake', 'choices' => [{ 'delta' => {} }],
                                          'usage' => usage)}\n\n"
        chunks << "data: [DONE]\n\n"
        @responses << { sse: chunks }
        self
      end

      private

      # One OpenAI chat-completion body: an assistant message, optionally with
      # +tool_calls+.
      #
      # @param content [String, nil]
      # @param tool_calls [Array<Hash>, nil]
      # @return [Hash]
      def assistant_body(content:, tool_calls: nil)
        message = { 'role' => 'assistant', 'content' => content }
        message['tool_calls'] = tool_calls if tool_calls
        { 'model' => 'fake', 'choices' => [{ 'message' => message }], 'usage' => usage }
      end

      # Nominal token counts so a {Agent::Event::Tokens} still fires.
      #
      # @return [Hash{String => Integer}]
      def usage
        { 'prompt_tokens' => 10, 'completion_tokens' => 5, 'total_tokens' => 15 }
      end
    end

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
