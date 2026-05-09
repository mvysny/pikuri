# frozen_string_literal: true

require 'rainbow'
require 'tty-markdown'
require_relative 'chat_log'
require_relative 'openai_client'
require_relative 'tool/delegate'

# Drives the classic Thought / Tool-call / Observation loop against an
# OpenAI-compatible backend: send the conversation, execute any tool calls the
# model emits, append their results, and repeat until the model stops or the
# step budget is exhausted.
class Agent
  # @param client [OpenAIClient] transport used to talk to the model
  # @param system_prompt [String] system message prepended to every run
  # @param tools [Array<Tool>] tools the model is allowed to call; advertised
  #   to the client on every chat request
  # @param max_steps [Integer] hard cap on model round-trips per
  #   {#run_loop} invocation; must be positive
  # @return [Agent]
  # @raise [ArgumentError] if +max_steps+ is zero or negative
  def initialize(client:, system_prompt:, tools: [], max_steps: 10)
    raise ArgumentError, "max_steps must be positive, got #{max_steps}" if max_steps <= 0

    @client = client
    @tools = tools
    @log = ChatLog.new
    @log.system(system_prompt)
    @system_prompt = system_prompt
    @max_steps = max_steps
  end

  # @return [ChatLog]
  attr_reader :log

  # @return [OpenAIClient]
  attr_reader :client

  # @return [Array<Tool>]
  attr_reader :tools

  # Run the agent loop for a single user turn.
  #
  # Appends +user_message+ to {#log} (which already carries the system prompt
  # and any prior turns), then iterates: ask the model, execute any returned
  # tool calls, feed the observations back, until the model returns +:stop+.
  # Reasoning, assistant messages, and tool invocations are printed to stdout
  # as they happen. Subsequent calls keep building on the same log, so the
  # model sees full multi-turn history.
  #
  # @param user_message [String] the user's request for this turn
  # @return [nil] nothing
  # @raise [RuntimeError] if the loop exceeds +max_steps+ without the model
  #   finishing, or if the model returns an unexpected +finish_reason+
  def run_loop(user_message:)
    log.user(user_message)

    @max_steps.times do
      response = @client.chat(log, tools: @tools)

      puts Rainbow(response.reasoning).darkgray if response.reasoning && !response.reasoning.empty?
      puts TTY::Markdown.parse(response.message) if response.message && !response.message.empty?

      log.assistant(content: response.message, tool_calls: response.tool_calls)

      case response.finish_reason
      when :stop
        return
      when :tool_calls
        response.tool_calls.each do |tc|
          result = tc.run
          puts Rainbow("→ #{tc} = #{result.inspect}").cyan
          log.tool(result, tool_call_id: tc.id)
        end
      else
        raise "Unexpected finish_reason: #{response.finish_reason.inspect}"
      end
    end

    raise "Agent loop exceeded #{@max_steps} steps without finishing"
  end

  # Adds a `delegate` tool which allows this agent to spin up sub-agents.
  def allow_delegate
    sub_tools = @tools.dup
    @tools << Tool.delegate(client: @client, system_prompt: @system_prompt, tools: sub_tools, max_steps: @max_steps)
  end
end
