#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require_relative 'lib/agent'
require_relative 'lib/openai_client'

client = OpenAIClient.new(
  url: 'http://192.168.122.1:8080/v1',
  model: 'unsloth/Qwen3.6-35B-A3B-GGUF',
  api_key: 'not-needed',
  tools: [WEB_SEARCH_TOOL]
)

agent = Agent.new(
  client: client,
  system_prompt: File.read('smolagents-system-prompt.txt')
)

agent.run_loop(user_message: 'How many seconds would it take for a leopard at full speed to run through Pont des Arts?')

puts agent.log
