# frozen_string_literal: true

module Pikuri
  class Agent
    # Prompt builder for the step-exhaustion rescue. When an +Agent+'s
    # {Control::StepLimit} trips with the +:synthesize+ policy, +Agent#run_loop+
    # runs this prompt on a nested tools-free agent so the run still produces an
    # answer from whatever evidence the failed agent gathered before running out
    # of budget.
    #
    # The failure mode it salvages is the "wait, but what about X?" death-loop:
    # the agent collects sound evidence in the first few rounds, then burns the
    # rest of the budget second-guessing — by the cap, the answer is largely in
    # the messages and just needs a tools-free pass to synthesize. Salvage is
    # wrong for some agents (a coding agent's half-finished work can only be
    # described, not completed), which is why the policy lives on
    # {Control::StepLimit} and defaults to +:raise+.
    #
    # Pure prompt construction — no chat handling or +RubyLLM.chat+ call.
    # {.run_synthesizer} owns the execution (a regular tools-free +Agent+, the
    # same shape sub-agents use). The only +RubyLLM::*+ surface read here is the
    # +RubyLLM::Message+/+ToolCall+ value-type passthrough.
    module Synthesizer
      # The synthesizer's system prompt. Strict and short: use
      # the evidence, don't apologize, admit gaps when present.
      SYSTEM_PROMPT = <<~PROMPT
        You are given evidence another agent collected before running out of steps. Answer the user's question using only this evidence. You have no tools. If the evidence is insufficient, state plainly what's missing and what partial answer you can give. Do not apologize or comment on the previous agent.
      PROMPT

      # Render the question plus an "Evidence gathered" section from
      # +parent_messages+. Pure — no I/O.
      #
      # @param parent_messages [Array<RubyLLM::Message>]
      # @param user_message [String]
      # @return [String]
      def self.build_prompt(parent_messages:, user_message:)
        transcript = format_evidence(parent_messages)
        "Question: #{user_message}\n\nEvidence gathered:\n#{transcript}"
      end

      # Walk the parent's history into a paired "Tool call:" / "Tool result:"
      # log, in order. Tool calls with no matching +:tool+ message are dropped —
      # the call that tripped the limit never executed, so citing its
      # nonexistent result would mislead the synth. Non-empty assistant text
      # becomes a "Note:" line.
      #
      # @param messages [Array<RubyLLM::Message>]
      # @return [String]
      def self.format_evidence(messages)
        results_by_id = messages
                        .select { |m| m.role == :tool }
                        .to_h { |m| [m.tool_call_id, m.content] }

        lines = []
        messages.each do |msg|
          next unless msg.role == :assistant

          text = msg.content
          lines << "Note: #{text}" if text.is_a?(String) && !text.empty?

          msg.tool_calls&.each_value do |tc|
            result = results_by_id[tc.id]
            next unless result

            args = tc.arguments.map { |k, v| "#{k}=#{v.inspect}" }.join(', ')
            lines << "Tool call: #{tc.name}(#{args})"
            lines << "Tool result: #{result}"
            lines << ''
          end
        end
        lines.join("\n").rstrip
      end
      private_class_method :format_evidence

      # The +:synthesize+ arm of the step-exhaustion policy. Runs the
      # {Synthesizer} prompt over the exhausted chat's history on a nested
      # tools-free +Agent+ (the sub-agent construction shape, so it inherits
      # listener propagation, transport/cap/streaming, and +close+ teardown).
      #
      # @param ctx [ExtensionContext]
      # @param chat_messages [Array<RubyLLM::Message>] the exhausted chat's
      #   history, the evidence {.build_prompt} renders
      # @param user_message [String] the user's original question
      # @raise [Control::Cancellable::Cancelled] when a cancel landed between
      #   the budget tripping and this rescue — cancellation wins over salvage
      # @return [String] the synth answer
      def self.run_synthesizer(ctx, chat_messages, user_message)
        # Check the cancel flag *before* constructing the synth: the nested
        # run_loop resets the shared cancellable at its turn boundary, which
        # would erase a cancel requested in this window. The raise propagates
        # without a parent-side {Event::Cancelled} — a cancel *during* synthesis
        # emits it from the synth's own rescue instead, so the stream sees at
        # most one.
        ctx.agent.cancellable&.check!

        ctx.emit_event(Event::FallbackNotice.new(
                         reason: "agent exhausted #{ctx.agent.step_limit.max} steps; " \
                                                 'synthesizing answer from gathered evidence'
                       ))

        # Synth runs under this agent's identity with a distinct +_synthesizer+
        # id suffix (same +_+ separator the sub-agent generator uses), so a
        # +TokenLog+ tags its turns as the rescue, not the loop.
        synth_id = ctx.agent.id.empty? ? 'synthesizer' : "#{ctx.agent.id}_synthesizer"
        synth = Agent.new(
          # Carry the parent's resolved cap on the transport so the synth reuses
          # it without a re-probe (the cap rides {ChatTransport}).
          transport: ctx.agent.transport.with(context_window: ctx.agent.context_window_cap),
          system_prompt: Synthesizer::SYSTEM_PROMPT,
          # Defensive :raise budget: the synth has no tools so should never
          # tick, but a buggy provider returning a tool call must not loop — a
          # synth that needs its own synth is a bug, not a rescue.
          step_limit: Control::StepLimit.new(max: 1),
          cancellable: ctx.agent.cancellable,
          id: synth_id,
          streaming: ctx.agent.streaming
        ) { |c| c.add_listeners(ctx.sub_agent_listeners(id: synth_id)) }
        begin
          synth.run_loop(user_message: Synthesizer.build_prompt(
            parent_messages: chat_messages, user_message: user_message
          ))
          synth.last_assistant_content
        ensure
          synth.close
        end
      end
    end
  end
end
