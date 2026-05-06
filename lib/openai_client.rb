require "faraday"
require "json"

class OpenAIClient
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
    response.body.dig("choices", 0, "message", "content")
  end
end
