# frozen_string_literal: true

require 'faraday'
require 'json'

# Thin Faraday-based client for OpenAI-compatible chat-completions endpoints
# such as a local llama.cpp server or x.ai. Returned messages carry both the
# main content and any +reasoning_content+ emitted by thinking models.
class OpenAIClient
  # Pair of assistant message content and (optional) reasoning content from a
  # single chat-completion choice.
  #
  # @!attribute [r] message
  #   @return [String] the assistant's message text
  # @!attribute [r] reasoning
  #   @return [String, nil] the +reasoning_content+ field for thinking models,
  #     or +nil+ when the model does not emit one
  Response = Data.define(:message, :reasoning)

  # @param url [String] base URL of the OpenAI-compatible endpoint, e.g.
  #   +"http://localhost:8080/v1"+
  # @param model [String] model identifier sent in each request body
  # @param api_key [String] bearer token; pass any non-empty placeholder for
  #   servers that do not check it (e.g. local llama.cpp)
  # @return [OpenAIClient]
  def initialize(url:, model:, api_key:)
    @model = model
    @conn = Faraday.new(url: url) do |f|
      f.request :json
      f.response :json
      f.headers['Authorization'] = "Bearer #{api_key}"
    end
  end

  # Send a single user message and return the assistant's reply.
  #
  # @param message [String] the user prompt text
  # @return [Response] the assistant's message and optional reasoning content
  # @raise [RuntimeError] if the HTTP call fails, the response shape is
  #   unexpected, or the message content is missing
  def chat(message)
    response = @conn.post('chat/completions', {
                            model: @model,
                            messages: [{ role: 'user', content: message }]
                          })
    raise "OpenAI request failed: #{response.status} #{response.body}" unless response.success?

    choices = response.body['choices']
    unless choices.is_a?(Array) && choices.size == 1
      raise "Expected exactly 1 choice, got #{choices&.size.inspect}: #{response.body}"
    end

    msg = choices[0]['message']
    content = msg && msg['content']
    raise "Missing message content in response: #{response.body}" if content.nil?

    Response.new(message: content, reasoning: msg['reasoning_content'])
  end
end
