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
# Listeners live in a {ListenerList} the caller supplies — duck-typed
# against a tiny +attach(chat)+ / +on_message(msg)+ protocol, with the
# list itself implementing the same protocol so +Agent+ never touches
# the underlying +Array+. There are no defaults for +tools:+ or
# +listeners:+ on {#initialize}: both are conscious decisions the
# caller must state every time.
#
# == Step-exhaustion rescue
#
# If a {Listener::StepLimit} in {#listeners} trips during +Chat#ask+,
# {#run_loop} catches the +Exceeded+ exception, emits a
# {Message::FallbackNotice} to every listener, and hands off to
# {Synthesizer.run} on a fresh +RubyLLM::Chat+. The synth reuses the
# parent's {ListenerList} (via {ListenerList#with_max_steps} called
# with +1+ — the synth has no tools, so the cap is defensive
# hardening) so its reasoning and answer flow through the same
# surface. The synth's answer becomes the value reported by
# {#last_assistant_content}, so callers (notably {Tool::SubAgent})
# still get a usable reply instead of raising past +bin/pikuri+.
class Agent
  # @param model [String, nil] LLM identifier; defaults to
  #   +RubyLLM.config.default_model+ so transport configuration can pick
  #   the model
  # @param system_prompt [String] system message prepended to the chat
  # @param tools [Array<Tool>] pikuri tools registered with the
  #   underlying chat in declaration order. Each is converted to
  #   ruby_llm's runtime shape via {Tool#to_ruby_llm_tool} when wired
  #   in. Required — no default, because the tool set is a deliberate
  #   per-call decision (pass +[]+ for a tools-free agent).
  # @param listeners [ListenerList] the listener list whose +attach+
  #   the constructor calls on the underlying chat. Required — no
  #   default, because the renderer and step-budget choices are
  #   deliberate per-call decisions. Typical CLI shape:
  #   +ListenerList.new([Listener::Terminal.new, Listener::StepLimit.new(max: 20)])+.
  # @param provider [Symbol, nil] forwarded to +RubyLLM.chat+. Required
  #   together with +assume_model_exists+ when pointing at a local
  #   OpenAI-compatible server (llama.cpp, gpustack, ...) whose model
  #   ids are not in ruby_llm's registry. Stored so the synthesizer
  #   rescue can construct a fresh chat with the same transport.
  # @param assume_model_exists [Boolean] forwarded to +RubyLLM.chat+;
  #   set to +true+ to skip the registry lookup and trust the supplied
  #   +model+ id. Requires +provider+.
  # @return [Agent]
  def initialize(system_prompt:, tools:, listeners:, model: nil,
                 provider: nil, assume_model_exists: false)
    @model = model || RubyLLM.config.default_model
    @system_prompt = system_prompt
    @tools = tools.dup
    @listeners = listeners
    @provider = provider
    @assume_model_exists = assume_model_exists
    @synth_answer = nil

    @chat = RubyLLM.chat(model: @model, provider: @provider, assume_model_exists: @assume_model_exists)
    @chat.with_instructions(@system_prompt)
    @tools.each { |t| @chat.with_tool(t.to_ruby_llm_tool) }
    @listeners.attach(@chat)
  end

  # @return [RubyLLM::Chat] underlying chat; the extension seam
  attr_reader :chat

  # @return [String]
  attr_reader :model

  # @return [String]
  attr_reader :system_prompt

  # @return [ListenerList] the listener list attached to this agent's
  #   chat
  attr_reader :listeners

  # Final assistant message content for the most recent {#run_loop}.
  # When the synthesizer rescue fired, returns its answer; otherwise
  # walks the underlying chat's history. Returns +nil+ if neither
  # source has produced an assistant turn yet.
  #
  # @return [String, nil]
  def last_assistant_content
    return @synth_answer if @synth_answer

    last = @chat.messages.reverse.find { |m| m.role == :assistant }
    last&.content
  end

  # Run the agent loop for a single user turn. Notifies every listener of
  # the {Message::User} — which is also how {Listener::StepLimit}
  # learns to reset its counter — and forwards +user_message+ to
  # {#chat} via +ask+. Returns nil; rendering and any other observable
  # output is the listeners' responsibility.
  #
  # If a {Listener::StepLimit} trips during +ask+, the rescue branch
  # emits a {Message::FallbackNotice} and runs {Synthesizer.run} on a
  # fresh +RubyLLM::Chat+. The synth's answer is captured for
  # {#last_assistant_content}; the exception does not bubble out.
  #
  # Subsequent calls keep building on the same chat history, so the
  # model sees full multi-turn context.
  #
  # @param user_message [String] the user's request for this turn
  # @return [nil]
  def run_loop(user_message:)
    @synth_answer = nil
    @listeners.on_message(Message::User.new(content: user_message))
    @chat.ask(user_message)
    nil
  rescue Listener::StepLimit::Exceeded => e
    notice = Message::FallbackNotice.new(
      reason: "agent exhausted #{e.max_steps} steps; synthesizing answer from gathered evidence"
    )
    @listeners.on_message(notice)

    synth_chat = RubyLLM.chat(model: @model, provider: @provider, assume_model_exists: @assume_model_exists)
    @synth_answer = Synthesizer.run(
      chat: synth_chat,
      parent_messages: @chat.messages,
      user_message: user_message,
      listeners: @listeners.with_max_steps(1)
    )
    nil
  end

  # Adds a +sub_agent+ tool that lets this agent spawn sub-agents which
  # share the parent's model, system prompt, and current tool set (minus
  # the sub-agent tool itself, so recursion is impossible).
  #
  # Each sub-agent run gets a derived {ListenerList} via
  # {ListenerList#with_max_steps} — the non-+StepLimit+ listeners
  # (Terminal, InMemoryList, ...) are shared so the sub-agent's
  # events render and capture continuously with the parent's, but
  # the +StepLimit+ is fresh so its tool-call budget is independent.
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
      listeners: @listeners,
      max_steps: max_steps
    )
    @tools << sub_tool
    @chat.with_tool(sub_tool.to_ruby_llm_tool)
  end

  # Short, single-line config dump suitable for a startup banner or a
  # debug print. Delegates the listener rendering to {ListenerList#to_s}.
  #
  # @example
  #   agent.to_s
  #   # => "Agent(model=qwen3-35b, tools=4, listeners=[Terminal, StepLimit(max=20)])"
  #
  # @return [String]
  def to_s
    "Agent(model=#{@model}, tools=#{@tools.size}, listeners=#{@listeners})"
  end
end
