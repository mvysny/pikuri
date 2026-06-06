# frozen_string_literal: true

module Pikuri
  class Agent
    # Prompt builder for the step-exhaustion rescue. When an
    # +Agent+'s {Control::StepLimit} trips with the +:synthesize+
    # policy, +Agent#run_loop+ runs this module's prompt on a
    # nested tools-free agent so the run still produces something
    # useful — an assistant turn that answers the user's question
    # from whatever evidence the failed agent collected before
    # running out of budget.
    #
    # == Why this exists
    #
    # Without a rescue, a step-exhausted run just raises a stack
    # trace past +bin/pikuri-chat+ and the user gets nothing
    # despite the agent having gathered useful information in the
    # first N-1 steps. The observed failure mode is the "wait,
    # but what about X?" death-loop: the agent collects sound
    # evidence in the first few rounds, then spends the rest of
    # the budget second-guessing. By the time the cap trips, the
    # answer is largely in the messages — it just needs a
    # tools-free pass to synthesize.
    #
    # Salvage is the wrong move for some agents, which is why the
    # policy lives on {Control::StepLimit} and defaults to
    # +:raise+ — a coding agent's half-finished work can't be
    # completed by a tools-free pass, only described. See
    # {Control::StepLimit}'s class header.
    #
    # == Seam discipline
    #
    # This module is pure prompt construction — no chat handling,
    # no +RubyLLM.chat+ call, no event wiring. The execution side
    # (constructing the nested agent, sharing the parent's
    # listener stream and cancellable, capturing the answer) is
    # +Agent#run_synthesizer+'s job: the synth is a regular
    # tools-free +Agent+, the same construction shape the +agent+
    # tool from +pikuri-subagents+ uses for sub-agents. The only
    # +RubyLLM::*+ surface read here is the value-type
    # +RubyLLM::Message+ / +ToolCall+ passthrough (per the
    # value-type rule in CLAUDE.md).
    module Synthesizer
      # The synthesizer's system prompt. Strict and short: use
      # the evidence, don't apologize, admit gaps when present.
      SYSTEM_PROMPT = <<~PROMPT
        You are given evidence another agent collected before running out of steps. Answer the user's question using only this evidence. You have no tools. If the evidence is insufficient, state plainly what's missing and what partial answer you can give. Do not apologize or comment on the previous agent.
      PROMPT

      # Render the user's question plus an "Evidence gathered"
      # section built from +parent_messages+ as a single prompt
      # string. Pure function — no I/O, safe to test directly
      # with fixture messages.
      #
      # @param parent_messages [Array<RubyLLM::Message>]
      # @param user_message [String]
      # @return [String]
      def self.build_prompt(parent_messages:, user_message:)
        transcript = format_evidence(parent_messages)
        "Question: #{user_message}\n\nEvidence gathered:\n#{transcript}"
      end

      # Walk the parent's message history and produce a paired
      # "Tool call:" / "Tool result:" log, preserving order. Tool
      # calls that have no matching +:tool+ message are dropped —
      # the call that tripped the step limit never executed, so
      # including it would mislead the synth into citing
      # nonexistent results. Non-empty assistant text content is
      # preserved as a "Note:" line, since the parent may have
      # summarized progress between tool calls.
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
    end
  end
end
