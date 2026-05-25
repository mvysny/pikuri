# frozen_string_literal: true

module Pikuri
  class Agent
    # Step-exhaustion rescue. When an +Agent+'s
    # {Control::StepLimit} trips, +Agent#run_loop+ catches the
    # +Exceeded+ exception and hands off to {Synthesizer.run} so
    # the run still produces something useful — a tools-free
    # assistant turn that answers the user's question from
    # whatever evidence the failed agent collected before running
    # out of budget.
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
    # == Seam discipline
    #
    # {Synthesizer.run} does not reference +RubyLLM::*+. +Agent+
    # constructs the synth chat itself (the one +RubyLLM.chat+
    # call lives in +lib/agent.rb+, same as the parent chat) and
    # passes it in. +Synthesizer+ only calls instance methods on
    # whatever +chat+ it receives — +#with_instructions+,
    # +#ask+, +#messages+ — and uses {Agent.wire_chat} for the
    # event-stream wiring so the synth chat emits events with
    # the same shape as the main chat.
    module Synthesizer
      # The synthesizer's system prompt. Strict and short: use
      # the evidence, don't apologize, admit gaps when present.
      SYSTEM_PROMPT = <<~PROMPT
        You are given evidence another agent collected before running out of steps. Answer the user's question using only this evidence. You have no tools. If the evidence is insufficient, state plainly what's missing and what partial answer you can give. Do not apologize or comment on the previous agent.
      PROMPT

      # Configure +chat+ for synthesis, run one turn against it,
      # and return the final assistant content. The chat is wired
      # for the event stream via {Agent.wire_chat} so the synth's
      # reasoning and answer flow through the same listener
      # surface the parent agent uses — terminal renders them
      # inline (padded under sub-agent), an in-memory recorder
      # picks them up, a TokenLog tags them with the synth id.
      #
      # @param chat [RubyLLM::Chat] a *fresh* chat with no tools.
      #   The caller is responsible for constructing it with the
      #   same model/provider configuration the parent used.
      # @param parent_messages [Array<RubyLLM::Message>] the
      #   parent chat's full message history at the moment of
      #   step exhaustion. Used to build the evidence transcript.
      # @param user_message [String] the user's original question
      #   from the parent turn that exhausted.
      # @param listeners [Agent::ListenerList] listeners to wire
      #   the synth chat into. Typically the parent agent's list
      #   run through {ListenerList#for_sub_agent} with the
      #   synth's +id:+ so any +TokenLog+ tags its lines with
      #   the synth bracket and any +Terminal+ pads its output.
      # @param step_limit [Control::StepLimit, nil] defensive
      #   step budget. The synth has no tools so it should never
      #   trip +before_tool_call+, but a buggy provider that
      #   somehow returned a tool call would loop without one.
      #   Pass +nil+ to skip.
      # @param cancellable [Control::Cancellable, nil]
      #   cancellation control. Typically the parent's instance,
      #   shared by reference so a user cancel during synthesis
      #   still works. Pass +nil+ to skip.
      # @param streaming [Boolean] mirror the parent agent's
      #   +streaming+ flag. When +true+, {Agent.streaming_block}
      #   is passed to +chat.ask+ so the synth's reasoning and
      #   answer flow through the listener stream as deltas in
      #   addition to the final {Event::Thinking} / {Event::Assistant}
      #   bookends.
      # @return [String, nil] the synth's final assistant
      #   content, or +nil+ if the synth somehow produced no
      #   assistant message
      def self.run(chat:, parent_messages:, user_message:, listeners:,
                   step_limit: nil, cancellable: nil, streaming: false)
        chat.with_instructions(SYSTEM_PROMPT)
        Agent.wire_chat(chat, listeners: listeners, step_limit: step_limit, cancellable: cancellable)
        prompt = build_prompt(parent_messages: parent_messages, user_message: user_message)
        if streaming
          chat.ask(prompt, &Agent.streaming_block(listeners: listeners, cancellable: cancellable))
        else
          chat.ask(prompt)
        end
        chat.messages.reverse.find { |m| m.role == :assistant }&.content
      end

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
