#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require_relative 'lib/agent'
require_relative 'lib/openai_client'
require_relative 'lib/tool/calculator'
require_relative 'lib/tool/websearch'

client = OpenAIClient.new(
  url: 'http://192.168.122.1:8080/v1',
  model: 'unsloth/Qwen3.6-35B-A3B-GGUF',
  api_key: 'not-needed'
)

agent = Agent.new(
  client: client,
  system_prompt: File.read('smolagents-system-prompt.txt'),
  tools: [Tool::WEB_SEARCH, Tool::CALCULATOR]
)
agent.allow_delegate

question =
  if ARGV.empty?
    print 'Question: '
    gets.to_s.chomp
  else
    ARGV.join(' ')
  end

agent.run_loop(user_message: question)

# To review the entire conversation:
# puts agent.log
