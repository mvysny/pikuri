# frozen_string_literal: true

require 'ruby_llm'

module Pikuri
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
  # it should never trip), +InMemoryMessageList+ shared by reference. The
  # listener +name:+ becomes +"<@name>_synthesizer"+ (or just
  # +"synthesizer"+ for the main agent) so the synth turn is distinct
  # from the parent's normal turns in any name-aware log line. The
  # synth's answer becomes the value reported by
  # {#last_assistant_content}, so callers (notably {Tool::SubAgent})
  # still get a usable reply instead of raising past +bin/pikuri-chat+.
  class Agent
    # @param transport [ChatTransport] the model-resolution triple
    #   (+model+ / +provider+ / +assume_model_exists+) forwarded to
    #   +RubyLLM.chat+. Bundled into one value object so every
    #   construction site — this constructor and the synthesizer rescue
    #   below — can forward all three with one assignment instead of
    #   three kwargs (where dropping one would silently route the chat
    #   elsewhere or raise +RubyLLM::ModelNotFoundError+). If
    #   +transport.model+ is +nil+, it's filled in from
    #   +RubyLLM.config.default_model+.
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
    #   derived by +bin/pikuri-chat+ from its configured +openai_api_base+;
    #   leave +nil+ when the configured server is anything other than
    #   llama.cpp.
    # @param name [String] identifier for this agent. Empty for the main
    #   agent; sub-agents get monotonic hierarchical names like
    #   +"sub_agent 0"+, +"sub_agent 1"+, +"sub_agent 0_0"+, ... generated
    #   by {Tool::SubAgent} from the parent's name + a per-parent counter.
    #   Forwarded to listeners through {ListenerList#for_sub_agent} so
    #   name-aware ones (notably {Listener::TokenLog}) can tag their output.
    # @param skill_catalog [Tool::SkillCatalog] catalog of on-disk skills
    #   the agent may load on demand. Defaults to
    #   +Tool::SkillCatalog::EMPTY+, which is a no-op singleton. When
    #   non-empty: the catalog's prompt block ({Tool::SkillCatalog#format_for_prompt})
    #   is appended to +system_prompt+ so the LLM can see what's available,
    #   and a {Tool::Skill} bound to the catalog is appended to +tools+
    #   so the LLM can actually load them. The two changes are coupled —
    #   advertising skills without a loader (or vice versa) would be a
    #   bug, so the catalog is the single source of truth for both.
    # @return [Agent]
    def initialize(transport:, system_prompt:, tools:, listeners:,
                   context_window: nil, llama_probe_url: nil, name: '',
                   skill_catalog: Tool::SkillCatalog::EMPTY)
      @transport = transport.model ? transport : transport.with(model: RubyLLM.config.default_model)
      @system_prompt = skill_catalog.empty? ? system_prompt : system_prompt + skill_catalog.format_for_prompt
      @skill_catalog = skill_catalog
      @tools = tools.dup
      @listeners = listeners
      @name = name
      @synth_answer = nil

      unless skill_catalog.empty?
        raise 'Tool::Skill cannot be passed in tools: when skill_catalog is non-empty; ' \
              'Agent auto-registers it from the catalog.' \
          if @tools.any?(Tool::Skill)

        @tools << Tool::Skill.new(catalog: skill_catalog)
      end

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
    #   rescue, the sub-agent tool). Read by {Tool::SubAgent} so
    #   spawned sub-agents reuse the same transport.
    attr_reader :transport

    # @return [Array<Tool>] this agent's tool list in declaration order.
    #   Snapshotted by {Tool::SubAgent} so spawned sub-agents inherit
    #   the parent's tools (minus the sub-agent tool itself, which
    #   {#allow_sub_agent} appends to +@tools+ only after the snapshot
    #   has been taken — recursion guard).
    attr_reader :tools

    # @return [String] resolved model id from {#transport}. Convenience
    #   delegator for callers that don't need the full transport bundle.
    def model
      @transport.model
    end

    # @return [String] system prompt actually sent to the chat — equal to
    #   the constructor's +system_prompt:+ argument plus, when a non-
    #   empty +skill_catalog:+ was supplied, the catalog's
    #   +<available_skills>+ block. {Tool::SubAgent} forwards this
    #   already-augmented value to spawned sub-agents, so they see the
    #   same catalog without needing the +skill_catalog:+ kwarg themselves.
    attr_reader :system_prompt

    # @return [Tool::SkillCatalog] catalog passed to the constructor;
    #   +Tool::SkillCatalog::EMPTY+ if none was supplied. Read by callers
    #   that want to inspect the loaded skills (e.g. for a startup banner).
    attr_reader :skill_catalog

    # @return [ListenerList] the listener list attached to this agent's
    #   chat
    attr_reader :listeners

    # @return [String] this agent's identifier — empty for the main agent;
    #   for sub-agents, the hierarchical id assigned by
    #   {Tool::SubAgent} (e.g. +"sub_agent 0"+, +"sub_agent 1"+,
    #   +"sub_agent 0_0"+). Read by the sub-agent tool so spawned
    #   sub-agents prefix their own names with this one, and propagated
    #   to listeners via {ListenerList#for_sub_agent} so name-aware ones
    #   can tag output.
    attr_reader :name

    # @return [Integer, nil] context-window cap resolved by
    #   {ContextWindowDetector} at construction time. +nil+ when no
    #   source produced a value (custom local model with no override and
    #   no reachable llama.cpp +/props+). Read by {Tool::SubAgent} so
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
    # @param user_message [String] the user's request for this turn; must
    #   not be +nil+, empty, or whitespace-only
    # @raise [ArgumentError] if +user_message+ is +nil+, empty, or
    #   contains only whitespace — an empty turn would poison the chat
    #   history and burn a step budget on nothing
    # @return [nil]
    def run_loop(user_message:)
      raise ArgumentError, "user_message must not be blank, got #{user_message.inspect}" \
        if user_message.nil? || user_message.to_s.strip.empty?

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
      # Synth runs under this agent's identity but on a fresh chat with a
      # different system prompt, so it gets a distinct +_synthesizer+
      # suffix on the name — same +_+ separator the sub-agent generator
      # uses, so main becomes +"synthesizer"+ and a sub-agent
      # +"sub_agent 0"+ becomes +"sub_agent 0_synthesizer"+. Any
      # +TokenLog+ in the list tags the synth's prompt under that bracket
      # so it's obvious from the log which turns were the rescue rather
      # than the original loop.
      synth_name = @name.empty? ? 'synthesizer' : "#{@name}_synthesizer"
      @synth_answer = Synthesizer.run(
        chat: synth_chat,
        parent_messages: @chat.messages,
        user_message: user_message,
        listeners: @listeners.for_sub_agent(max_steps: 1, name: synth_name)
      )
      nil
    end

    # Adds a +sub_agent+ tool that lets this agent spawn sub-agents which
    # share the parent's model, system prompt, and current tool set (minus
    # the sub-agent tool itself, so recursion is impossible).
    #
    # {Tool::SubAgent} snapshots +@tools+ during construction; we append
    # the new sub-agent tool to +@tools+ only after that, so the
    # sub-agent's tool list never contains itself.
    #
    # Each sub-agent run gets a derived {ListenerList} via
    # {ListenerList#for_sub_agent} — listeners that define a sub-agent
    # variant return a fresh instance (e.g. +StepLimit+ at the new cap,
    # +Terminal+ with sub-agent padding, +TokenLog+ zeroed); listeners
    # without the hook (+InMemoryMessageList+, ...) are shared by reference so
    # the sub-agent's events render and capture continuously with the
    # parent's.
    #
    # @param max_steps [Integer] step budget for each sub-agent run,
    #   passed through to {Tool::SubAgent#initialize}
    # @raise [RuntimeError] if a {Tool::SubAgent} is already registered
    #   on this agent — calling twice would advertise two identically
    #   named tools to ruby_llm and double the sub-agent's tool list
    #   (the second snapshot would contain the first sub-agent tool).
    # @return [void]
    def allow_sub_agent(max_steps: 10)
      raise "Tool::SubAgent already registered on this agent; allow_sub_agent may only be called once" \
        if @tools.any?(Tool::SubAgent)

      sub_tool = Tool::SubAgent.new(self, max_steps: max_steps)
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
end
