#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'rainbow'
require_relative 'lib/openai_client'

MAX_STEPS = 10

weather_tool = Tool.new(
  name: 'get_weather',
  description: 'Returns the current weather for the given city.',
  parameters: Tool::Parameters.build { |p| p.required_string :city, 'City name, e.g. "Helsinki".' },
  execute: ->(city:) { "Weather in #{city}: warm, 20 C" }
)

client = OpenAIClient.new(
  url: 'http://192.168.122.1:8080/v1',
  model: 'unsloth/Qwen3.6-35B-A3B-GGUF',
  api_key: 'not-needed',
  tools: [weather_tool]
)

log = ChatLog.new
log.system('You are a helpful weather teller. When the user asks about the weather, call the get_weather tool with the city and report what it says.')
log.user("What's the weather in Helsinki?")

done = false
MAX_STEPS.times do
  response = client.chat(log)

  puts Rainbow(response.reasoning).darkgray if response.reasoning && !response.reasoning.empty?
  puts response.message if response.message && !response.message.empty?

  case response.finish_reason
  when :stop
    log.assistant(content: response.message, tool_calls: response.tool_calls)
    done = true
    break
  when :tool_calls
    log.assistant(content: response.message, tool_calls: response.tool_calls)
    response.tool_calls.each do |tc|
      result = tc.run
      puts Rainbow("→ #{tc} = #{result.inspect}").cyan
      log.tool(result, tool_call_id: tc.id)
    end
  else
    raise "Unexpected finish_reason: #{response.finish_reason.inspect}"
  end
end
raise "Agent loop exceeded #{MAX_STEPS} steps without finishing" unless done
