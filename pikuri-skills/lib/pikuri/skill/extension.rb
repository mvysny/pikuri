# frozen_string_literal: true

require 'pathname'

module Pikuri
  # Namespace for the Skills feature — the Agent Skills standard, as
  # {Catalog} (discovery) + {SkillTool} (load) + {Extension} (wiring).
  module Skill
    # An {Pikuri::Agent::Extension} that auto-wires the Agent Skills
    # standard onto an agent: appends the catalog's
    # +<available_skills>+ block to the system prompt and registers
    # the +skill+ tool so the LLM can load skill bodies on demand.
    # Empty catalog ⇒ no-op (no snippet, no tool).
    #
    # == Usage
    #
    #   catalog = Pikuri::Skill::Catalog::Bundled.new(
    #     search_bases: [project_root, Dir.home]
    #   )
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_extension Pikuri::Skill::Extension.new(catalog: catalog, root: project_root)
    #   end
    #
    # This contributes no +trifecta_contribution+ of its own, and that is
    # not an omission: the prompt block and {#schedule_load_skill} carry the
    # same bundles' bytes the +skill+ tool does, so they ride its +untrusted+
    # leg, which {Catalog#untrusted_level} grades over the whole stored set.
    #
    # +configure+ appends the prompt snippet + +skill+ tool (both inherited
    # verbatim by sub-agents via the tool snapshot); +bind+ additionally
    # captures the parent agent's interloper so a host can load a skill on
    # its *own* initiative via {#schedule_load_skill} — the UI-driven
    # counterpart of the +skill+ tool. Main-agent-only: sub-agents don't
    # inherit extensions.
    #
    # It also owns this conversation's {Activation} — which +paths:+-gated
    # skills have fired — and clears it when the host clears the conversation.
    class Extension
      include Pikuri::Agent::Extension

      # @param catalog [Pikuri::Skill::Catalog] the catalog of
      #   skills the agent may load. Required.
      # @param root [Pathname] the workspace root a touched path is resolved
      #   against before it is matched against a skill's +paths:+. Absolute,
      #   because that path is model-supplied and must never be read as
      #   relative to whatever the process's cwd happens to be.
      # @raise [ArgumentError] if +root+ is not an absolute +Pathname+
      def initialize(catalog:, root:)
        unless root.is_a?(Pathname) && root.absolute?
          raise ArgumentError, "root must be an absolute Pathname, got #{root.inspect}"
        end

        @catalog = catalog
        @root = root
        @activation = Pikuri::Skill::Activation.new(catalog: catalog)
      end

      # @return [Pikuri::Skill::Catalog]
      attr_reader :catalog

      # @return [Pathname]
      attr_reader :root

      # @return [Pikuri::Skill::Activation] which gated skills this
      #   conversation has in play
      attr_reader :activation

      # Register the +skill+ tool. No-op when the catalog is empty
      # (the +<available_skills>+ snippet is contributed by
      # {#system_prompt_snippets}).
      #
      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        return if @catalog.empty?

        if c.tools.any?(Pikuri::Skill::SkillTool)
          raise 'Pikuri::Skill::SkillTool cannot be pre-registered (in tools: or via c.add_tool) ' \
                'when adding Pikuri::Skill::Extension — the extension auto-registers it from the catalog.'
        end

        c.add_tool(Pikuri::Skill::SkillTool.new(activation: @activation))
        nil
      end

      # Capture the live agent's interloper so {#schedule_load_skill} can
      # enqueue onto it from any (UI) thread. +nil+ when the agent was built
      # without an +interloper:+ — {#schedule_load_skill} then raises.
      #
      # @param ctx [Pikuri::Agent::ExtensionContext]
      # @return [void]
      def bind(ctx)
        @interloper = ctx.agent.interloper
        nil
      end

      # Schedule a skill for injection into the conversation on the host's
      # own initiative — the UI-driven counterpart of the +skill+ tool. Looks
      # +name+ up in the catalog, renders its body identically to the tool,
      # and *enqueues* it on the interloper as a +:system+ block.
      #
      #   ext   = Pikuri::Skill::Extension.new(catalog: catalog, root: project_root)
      #   agent = Pikuri::Agent.new(..., interloper: interloper) { |c| c.add_extension ext }
      #   ext.schedule_load_skill('pdf-tools')    # enqueue only — nothing runs yet
      #   agent.run_loop(user_message: nil)        # bare turn: the agent reacts to the skill
      #
      # IMPORTANT: this only *enqueues*. Nothing happens until the host runs
      # the loop — {Pikuri::Agent#run_loop} drains the injection at turn
      # start, before the first completion. Enqueue-only keeps the call
      # non-blocking and thread-safe (the interloper is +Mutex+-guarded); it
      # never touches the loop or a worker thread. Two host choices, by how
      # the loop is then run:
      #
      # * bare load — +run_loop(user_message: nil)+: the agent reacts to the
      #   skill alone and says something — except on a system-hoisting provider,
      #   where a +:system+-only turn raises {Pikuri::Agent::EmptyTurnError} (the
      #   skill is still enqueued, so the host just prompts for a message).
      # * load + message — +run_loop(user_message: text)+: the skill block
      #   and the message both land before the model responds.
      #
      # Provider note: injected as +:system+, so on the default (llama.cpp /
      # OpenAI-family) the block sits positionally where it was loaded — a
      # one-shot, like the tool. On Anthropic every +:system+ message is
      # hoisted into the top-level system param, so a host-loaded skill is
      # *sticky*: it stays in force for the rest of the conversation, unlike
      # the tool's one-shot observation. Intended (a deliberately loaded
      # skill is session guidance), but an honest divergence between the two
      # load paths.
      #
      # @param name [String] a skill name from +catalog.list+; the UI
      #   enumerates the catalog, so a miss is a host bug
      # @raise [KeyError] if +name+ is not in the catalog
      # @raise [RuntimeError] if the agent was built without an +interloper:+
      #   (nowhere to enqueue)
      # @return [Pikuri::Skill::Catalog::Skill] the scheduled skill
      def schedule_load_skill(name)
        skill = @catalog.get(name)
        raise KeyError, "no skill named #{name.inspect} in the catalog" if skill.nil?

        raise 'schedule_load_skill needs an interloper — construct the Agent with `interloper:`' \
          if @interloper.nil?

        @interloper.inject_system_message(Pikuri::Skill::Renderer.format_skill(skill))
        skill
      end

      # Re-hide the gated skills. The clear dropped their promotions from the
      # log, so the next matching touch has to announce them again.
      #
      # @param ctx [Pikuri::Agent::ExtensionContext] unused; protocol signature.
      # @return [void]
      def on_conversation_reset(_ctx)
        @activation.reset
        nil
      end

      # The +<available_skills>+ catalog block (empty array for an
      # empty catalog). {Renderer.format_catalog} returns leading blank
      # lines; the Agent joins sections with +\n\n+, so +lstrip+ avoids
      # doubling them.
      #
      # @return [Array<String>]
      def system_prompt_snippets
        return [] if @catalog.empty?

        [Pikuri::Skill::Renderer.format_catalog(@catalog).lstrip]
      end
    end
  end
end
