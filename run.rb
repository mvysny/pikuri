#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require_relative 'lib/agent'
require_relative 'lib/openai_client'

weather_tool = Tool.new(
  name: 'get_weather',
  description: 'Returns the current weather for the given city.',
  parameters: Tool::Parameters.build { |p| p.required_string :city, 'City name, e.g. "Helsinki".' },
  execute: ->(city:) { "Weather in #{city}: warm, 20 C" }
)

client = OpenAIClient.new(
  url: 'http://127.0.0.1:8080/v1',
  model: 'unsloth/Qwen3.6-35B-A3B-GGUF',
  api_key: 'not-needed',
  tools: [weather_tool]
)

agent = Agent.new(
  client: client,
  system_prompt: 'You are a helpful weather teller. When the user asks about the weather, call the get_weather tool with the city and report what it says.'
)

agent.run_loop(user_message: "What's the weather in Helsinki?")

# To review the entire conversation:
# puts agent.log
