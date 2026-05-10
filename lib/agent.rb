# frozen_string_literal: true

require 'rainbow'
require 'tty-markdown'
require 'ruby_llm'
require_relative 'tool/sub_agent'

# Thin wrapper around +RubyLLM::Chat+: pikuri owns the *extension surface*
# (event listeners that print reasoning, assistant messages, tool calls,
# and the +max_steps+ guard) while ruby_llm owns the loop itself. See
# +MIGRATION.md+ for the larger framing — pikuri's Thought / Tool-call /
# Observation iteration moved into +Chat#complete+, and what used to be
# the body of +run_loop+ became the listener set installed in
# {#install_listeners}.
class Agent
  # @param model [String, nil] LLM identifier; defaults to
  #   +RubyLLM.config.default_model+ so transport configuration can pick
  #   the model
  # @param system_prompt [String] system message prepended to the chat
  # @param tools [Array<Class>] synthetic +RubyLLM::Tool+ subclasses (the
  #   shape returned by {Tool.new}). Registered with the underlying chat
  #   in declaration order.
  # @param max_steps [Integer] hard cap on tool-call rounds per
  #   {#run_loop} invocation; must be positive. Counted in the
  #   +before_tool_call+ listener and reset at the start of each run.
  # @param provider [Symbol, nil] forwarded to +RubyLLM.chat+. Required
  #   together with +assume_model_exists+ when pointing at a local
  #   OpenAI-compatible server (llama.cpp, gpustack, ...) whose model
  #   ids are not in ruby_llm's registry.
  # @param assume_model_exists [Boolean] forwarded to +RubyLLM.chat+;
  #   set to +true+ to skip the registry lookup and trust the supplied
  #   +model+ id. Requires +provider+.
  # @return [Agent]
  # @raise [ArgumentError] if +max_steps+ is zero or negative
  def initialize(model: nil, system_prompt:, tools: [], max_steps: 20,
                 provider: nil, assume_model_exists: false)
    raise ArgumentError, "max_steps must be positive, got #{max_steps}" if max_steps <= 0

    @model = model || RubyLLM.config.default_model
    @system_prompt = system_prompt
    @tools = tools.dup
    @max_steps = max_steps
    @step = 0

    @chat = RubyLLM.chat(model: @model, provider: provider, assume_model_exists: assume_model_exists)
    @chat.with_instructions(@system_prompt)
    @tools.each { |t| @chat.with_tool(t) }
    install_listeners
  end

  # @return [RubyLLM::Chat] underlying chat; the extension seam
  attr_reader :chat

  # @return [String]
  attr_reader :model

  # @return [String]
  attr_reader :system_prompt

  # Final assistant message content across the chat's history, or +nil+ if
  # the chat has not produced one yet. Used by {Tool.sub_agent}'s execute
  # lambda to surface only the sub-agent's last reply back to the parent.
  #
  # @return [String, nil]
  def last_assistant_content
    last = @chat.messages.reverse.find { |m| m.role == :assistant }
    last&.content
  end

  # Run the agent loop for a single user turn. Resets the step counter,
  # forwards +user_message+ to {#chat} via +ask+, and returns nil — all
  # rendering happens through the listeners installed at construction.
  #
  # Subsequent calls keep building on the same chat history, so the model
  # sees full multi-turn context.
  #
  # @param user_message [String] the user's request for this turn
  # @return [nil]
  # @raise [RuntimeError] if the loop exceeds +max_steps+ tool calls
  def run_loop(user_message:)
    @step = 0
    @chat.ask(user_message)
    nil
  end

  # Adds a +sub_agent+ tool that lets this agent spawn sub-agents which
  # share the parent's model, system prompt, and current tool set (minus
  # the sub-agent tool itself, so recursion is impossible).
  #
  # @return [void]
  def allow_sub_agent
    sub_tools = @tools.dup
    sub_tool = Tool.sub_agent(
      model: @model,
      system_prompt: @system_prompt,
      tools: sub_tools,
      max_steps: @max_steps
    )
    @tools << sub_tool
    @chat.with_tool(sub_tool)
  end

  private

  def install_listeners
    @chat.after_message do |msg|
      next unless msg.role == :assistant

      thinking_text = msg.thinking&.text
      puts Rainbow(thinking_text).darkgray if thinking_text && !thinking_text.empty?

      content = msg.content
      puts TTY::Markdown.parse(content) if content.is_a?(String) && !content.empty?
    end

    @chat.before_tool_call do |tc|
      @step += 1
      raise "Agent loop exceeded #{@max_steps} steps" if @step > @max_steps

      args = tc.arguments.map { |k, v| "#{k}=#{v.inspect}" }.join(', ')
      puts Rainbow("→ #{tc.name}(#{args})").cyan
    end

    @chat.after_tool_result do |result|
      puts Rainbow("= #{result}").cyan
    end
  end
end
