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
# parent's {ListenerList} via {ListenerList#for_sub_agent} with
# +max_steps: 1+ — same transformation a sub-agent invocation gets,
# since the synth is a fresh context: +TokenLog+ zeroed, +Terminal+
# padded, +StepLimit+ at the defensive cap (the synth has no tools so
# it should never trip), +InMemoryList+ shared by reference. The
# synth's answer becomes the value reported by
# {#last_assistant_content}, so callers (notably {Tool::SubAgent})
# still get a usable reply instead of raising past +bin/pikuri+.
class Agent
  # @param transport [ChatTransport] the model-resolution triple
  #   (+model+ / +provider+ / +assume_model_exists+) forwarded to
  #   +RubyLLM.chat+. Bundled into one value object so every
  #   construction site — this constructor, the synthesizer rescue
  #   below, and {Tool::SubAgent.build} — can forward all three with
  #   one assignment instead of three kwargs (where dropping one would
  #   silently route the chat elsewhere or raise
  #   +RubyLLM::ModelNotFoundError+). If +transport.model+ is +nil+,
  #   it's filled in from +RubyLLM.config.default_model+.
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
  # @param context_window [Integer, nil] explicit override for the
  #   model's context-window cap. When set, it wins over ruby_llm's
  #   reported value and the llama.cpp probe — see
  #   {ContextWindowDetector} for precedence. Resolved cap is pushed to
  #   every {Listener::TokenLog} so the +ctx=<used>/<cap>+ headline
  #   lights up.
  # @param llama_probe_url [String, nil] llama.cpp +/props+ URL used as
  #   the third detection source. Only consulted when neither
  #   +context_window+ nor ruby_llm's reported value is set. Typically
  #   derived by +bin/pikuri+ from its configured +openai_api_base+;
  #   leave +nil+ when the configured server is anything other than
  #   llama.cpp.
  # @return [Agent]
  def initialize(transport:, system_prompt:, tools:, listeners:,
                 context_window: nil, llama_probe_url: nil)
    @transport = transport.model ? transport : transport.with(model: RubyLLM.config.default_model)
    @system_prompt = system_prompt
    @tools = tools.dup
    @listeners = listeners
    @synth_answer = nil

    @chat = RubyLLM.chat(**@transport.to_h)
    @chat.with_instructions(@system_prompt)
    @tools.each { |t| @chat.with_tool(t.to_ruby_llm_tool) }

    @context_window_cap = ContextWindowDetector.new(
      override: context_window,
      ruby_llm_reported: @chat.model.context_window,
      llama_probe_url: llama_probe_url
    ).detect
    @listeners.context_window_cap = @context_window_cap
    @listeners.attach(@chat)
  end

  # @return [RubyLLM::Chat] underlying chat; the extension seam
  attr_reader :chat

  # @return [ChatTransport] the resolved transport bundle this agent
  #   was constructed with — same model id / provider /
  #   assume-model-exists flag passed to every +RubyLLM.chat+ call
  #   originating from this agent (the main chat, the synthesizer
  #   rescue, the sub-agent factory). Read by {#allow_sub_agent} so
  #   spawned sub-agents reuse the same transport without each call
  #   site re-listing the three fields.
  attr_reader :transport

  # @return [String] resolved model id from {#transport}. Convenience
  #   delegator for callers that don't need the full transport bundle.
  def model
    @transport.model
  end

  # @return [String]
  attr_reader :system_prompt

  # @return [ListenerList] the listener list attached to this agent's
  #   chat
  attr_reader :listeners

  # @return [Integer, nil] context-window cap resolved by
  #   {ContextWindowDetector} at construction time. +nil+ when no
  #   source produced a value (custom local model with no override and
  #   no reachable llama.cpp +/props+). Read by {#allow_sub_agent} so
  #   spawned sub-agents inherit the same cap without re-probing.
  attr_reader :context_window_cap

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

    synth_chat = RubyLLM.chat(**@transport.to_h)
    @synth_answer = Synthesizer.run(
      chat: synth_chat,
      parent_messages: @chat.messages,
      user_message: user_message,
      listeners: @listeners.for_sub_agent(max_steps: 1)
    )
    nil
  end

  # Adds a +sub_agent+ tool that lets this agent spawn sub-agents which
  # share the parent's model, system prompt, and current tool set (minus
  # the sub-agent tool itself, so recursion is impossible).
  #
  # Each sub-agent run gets a derived {ListenerList} via
  # {ListenerList#for_sub_agent} — listeners that define a sub-agent
  # variant return a fresh instance (e.g. +StepLimit+ at the new cap,
  # +Terminal+ with sub-agent padding, +TokenLog+ zeroed); listeners
  # without the hook (+InMemoryList+, ...) are shared by reference so
  # the sub-agent's events render and capture continuously with the
  # parent's.
  #
  # @param max_steps [Integer] step budget for each sub-agent run,
  #   passed through to {Tool::SubAgent.build}
  # @return [void]
  def allow_sub_agent(max_steps: 10)
    sub_tools = @tools.dup
    sub_tool = Tool.sub_agent(
      transport: @transport,
      system_prompt: @system_prompt,
      tools: sub_tools,
      listeners: @listeners,
      max_steps: max_steps,
      # Pass the parent's resolved cap as the sub-agent's override so it
      # doesn't re-probe /props on every invocation. If the parent's
      # detection returned nil, the sub-agent sees nil too — same model,
      # same server, same outcome.
      context_window: @context_window_cap
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
    "Agent(model=#{model}, tools=#{@tools.size}, listeners=#{@listeners})"
  end
end
