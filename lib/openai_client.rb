# frozen_string_literal: true

require 'faraday'
require 'json'
require_relative 'chat_response'

# Thin Faraday-based client for OpenAI-compatible chat-completions endpoints
# such as a local llama.cpp server or x.ai. Returned messages carry both the
# main content and any +reasoning_content+ emitted by thinking models.
class OpenAIClient
  # @param url [String] base URL of the OpenAI-compatible endpoint, e.g.
  #   +"http://localhost:8080/v1"+
  # @param model [String] model identifier sent in each request body
  # @param api_key [String] bearer token; pass any non-empty placeholder for
  #   servers that do not check it (e.g. local llama.cpp)
  # @return [OpenAIClient]
  def initialize(url:, model:, api_key:)
    @model = model
    @parser = ChatParser.new(tools: [])
    @conn = Faraday.new(url: url) do |f|
      f.request :json
      f.response :json
      f.headers['Authorization'] = "Bearer #{api_key}"
    end
  end

  # Send a single user message and return the assistant's reply.
  #
  # @param message [String] the user prompt text
  # @return [ChatResponse] the parsed chat-completion response
  # @raise [RuntimeError] if the HTTP call fails or the response shape is
  #   unexpected (see {ChatParser#parse})
  def chat(message)
    response = @conn.post('chat/completions', {
                            model: @model,
                            messages: [{ role: 'user', content: message }]
                          })
    raise "OpenAI request failed: #{response.status} #{response.body}" unless response.success?

    @parser.parse(response.body)
  end
end
