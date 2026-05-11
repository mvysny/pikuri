# frozen_string_literal: true

require 'ruby_llm'

# Thin wrapper around +RubyLLM::Chat+: pikuri owns the *extension surface*
# (the listener objects that consume normalized chat events) while
# ruby_llm owns the loop itself. The Thought / Tool-call / Observation
# iteration lives in +Chat#complete+; pikuri's job is just attaching
# listeners at construction time, forwarding the user turn, and
# notifying the listeners of the new {Message::User} so any that care
# about turn boundaries (notably {Listener::StepLimit}) can react.
#
# Listeners are duck-typed against a tiny protocol — +#attach(chat)+
# and +#on_message(msg)+. The constructor's default listener list
# (+Listener::Terminal+ for rendering + +Listener::StepLimit+ for the
# step budget) reproduces pikuri's standard CLI behavior; callers
# wanting structured event capture or a different step cap supply
# their own list.
class Agent
  # @param model [String, nil] LLM identifier; defaults to
  #   +RubyLLM.config.default_model+ so transport configuration can pick
  #   the model
  # @param system_prompt [String] system message prepended to the chat
  # @param tools [Array<Tool>] pikuri tools registered with the underlying
  #   chat in declaration order. Each is converted to ruby_llm's runtime
  #   shape via {Tool#to_ruby_llm_tool} when wired in.
  # @param listeners [Array] consumers of the normalized event stream.
  #   Each must respond to +#attach(chat)+ (register Chat hooks) and
  #   +#on_message(msg)+ (consume one {Message}). Default:
  #   +[Listener::Terminal.new, Listener::StepLimit.new(max: 20)]+,
  #   which matches pikuri's pre-refactor behavior. Pass an explicit
  #   list to swap renderers, add structured capture
  #   ({Listener::InMemoryList}), or change the step budget.
  # @param provider [Symbol, nil] forwarded to +RubyLLM.chat+. Required
  #   together with +assume_model_exists+ when pointing at a local
  #   OpenAI-compatible server (llama.cpp, gpustack, ...) whose model
  #   ids are not in ruby_llm's registry.
  # @param assume_model_exists [Boolean] forwarded to +RubyLLM.chat+;
  #   set to +true+ to skip the registry lookup and trust the supplied
  #   +model+ id. Requires +provider+.
  # @return [Agent]
  def initialize(model: nil, system_prompt:, tools: [],
                 listeners: [Listener::Terminal.new, Listener::StepLimit.new(max: 20)],
                 provider: nil, assume_model_exists: false)
    @model = model || RubyLLM.config.default_model
    @system_prompt = system_prompt
    @tools = tools.dup
    @listeners = listeners

    @chat = RubyLLM.chat(model: @model, provider: provider, assume_model_exists: assume_model_exists)
    @chat.with_instructions(@system_prompt)
    @tools.each { |t| @chat.with_tool(t.to_ruby_llm_tool) }
    @listeners.each { |l| l.attach(@chat) }
  end

  # @return [RubyLLM::Chat] underlying chat; the extension seam
  attr_reader :chat

  # @return [String]
  attr_reader :model

  # @return [String]
  attr_reader :system_prompt

  # @return [Array] the listeners attached to this agent's chat, in the
  #   order they were supplied
  attr_reader :listeners

  # Final assistant message content across the chat's history, or +nil+ if
  # the chat has not produced one yet. Used by {Tool.sub_agent}'s execute
  # lambda to surface only the sub-agent's final reply back to the parent.
  #
  # @return [String, nil]
  def last_assistant_content
    last = @chat.messages.reverse.find { |m| m.role == :assistant }
    last&.content
  end

  # Run the agent loop for a single user turn. Notifies every listener of
  # the {Message::User} — which is also how {Listener::StepLimit}
  # learns to reset its counter — and forwards +user_message+ to
  # {#chat} via +ask+. Returns nil; rendering and any other observable
  # output is the listeners' responsibility.
  #
  # Subsequent calls keep building on the same chat history, so the
  # model sees full multi-turn context.
  #
  # @param user_message [String] the user's request for this turn
  # @return [nil]
  # @raise [Listener::StepLimit::Exceeded] if a {Listener::StepLimit}
  #   in {#listeners} trips during +Chat#ask+
  def run_loop(user_message:)
    user_msg = Message::User.new(content: user_message)
    @listeners.each { |l| l.on_message(user_msg) }
    @chat.ask(user_message)
    nil
  end

  # Adds a +sub_agent+ tool that lets this agent spawn sub-agents which
  # share the parent's model, system prompt, and current tool set (minus
  # the sub-agent tool itself, so recursion is impossible).
  #
  # Sub-agents are independent: each call constructs a fresh +Agent+
  # with its own default listener list (Terminal + StepLimit), so the
  # parent's listeners are not shared.
  #
  # @param max_steps [Integer] step budget for each sub-agent run,
  #   passed through to {Tool::SubAgent.build}
  # @return [void]
  def allow_sub_agent(max_steps: 10)
    sub_tools = @tools.dup
    sub_tool = Tool.sub_agent(
      model: @model,
      system_prompt: @system_prompt,
      tools: sub_tools,
      max_steps: max_steps
    )
    @tools << sub_tool
    @chat.with_tool(sub_tool.to_ruby_llm_tool)
  end

  # Short, single-line config dump suitable for a startup banner or a
  # debug print. Each listener contributes its own +#to_s+.
  #
  # @example
  #   agent.to_s
  #   # => "Agent(model=qwen3-35b, tools=4, listeners=[Terminal, StepLimit(max=20)])"
  #
  # @return [String]
  def to_s
    "Agent(model=#{@model}, tools=#{@tools.size}, listeners=[#{@listeners.map(&:to_s).join(', ')}])"
  end
end
