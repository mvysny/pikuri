#!/usr/bin/env ruby
require "bundler/setup"
require "rainbow"
require_relative "lib/openai_client"

client = OpenAIClient.new(
  url: "http://192.168.122.1:8080/v1",
  model: "unsloth/Qwen3.6-35B-A3B-GGUF",
  api_key: "not-needed"
)

prompt = File.read(File.join(__dir__, "prompt.txt"))
response = client.chat(prompt)
puts Rainbow(response.reasoning).darkgray if response.reasoning
puts response.message
