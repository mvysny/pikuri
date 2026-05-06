require "faraday"
require "json"

class OpenAIClient
  Response = Data.define(:message, :reasoning)

  def initialize(url:, model:, api_key:)
    @model = model
    @conn = Faraday.new(url: url) do |f|
      f.request :json
      f.response :json
      f.headers["Authorization"] = "Bearer #{api_key}"
    end
  end

  def chat(message)
    response = @conn.post("chat/completions", {
      model: @model,
      messages: [{ role: "user", content: message }]
    })
    raise "OpenAI request failed: #{response.status} #{response.body}" unless response.success?

    choices = response.body["choices"]
    raise "Expected exactly 1 choice, got #{choices&.size.inspect}: #{response.body}" unless choices.is_a?(Array) && choices.size == 1

    msg = choices[0]["message"]
    content = msg && msg["content"]
    raise "Missing message content in response: #{response.body}" if content.nil?

    Response.new(message: content, reasoning: msg["reasoning_content"])
  end
end
