# frozen_string_literal: true

require 'faraday'
require 'json'
require_relative 'chat_log'
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
  # @param tools [Array<Tool>] tools advertised on every request, also used
  #   by the response parser to resolve incoming tool-call names
  # @return [OpenAIClient]
  def initialize(url:, model:, api_key:, tools: [])
    @model = model
    @tools = tools
    @parser = ChatParser.new(tools: tools)
    @conn = Faraday.new(url: url) do |f|
      f.request :json
      f.response :json
      f.headers['Authorization'] = "Bearer #{api_key}"
    end
  end

  # Send the conversation in +log+ to the model and return the parsed reply.
  #
  # @param log [ChatLog] conversation history to send
  # @return [ChatResponse] parsed chat-completion response
  # @raise [RuntimeError] if the HTTP call fails or the response shape is
  #   unexpected (see {ChatParser#parse})
  def chat(log)
    response = @conn.post('chat/completions', self.class.request_body(log, tools: @tools, model: @model))
    raise "OpenAI request failed: #{response.status} #{response.body}" unless response.success?

    @parser.parse(response.body)
  end

  # Translate a {ChatLog} + tools + model into the request Hash POSTed to
  # +/chat/completions+. Pure: returns a fresh Hash without touching the
  # network. Public so the wire-format mapping can be tested directly.
  #
  # Per-role wire shape:
  #
  # - +:system+, +:user+ → +{role:, content:}+
  # - +:assistant+ → +{role: 'assistant', content:, tool_calls: [...]}+;
  #   +tool_calls+ is omitted when none were emitted, and each entry is
  #   +{type: 'function', id:, function: {name:, arguments: <JSON string>}}+
  # - +:tool+ → +{role: 'tool', content:, tool_call_id:}+
  #
  # @param log [ChatLog]
  # @param tools [Array<Tool>] advertised tool list; the +tools+ key is
  #   omitted from the body when empty (some servers reject an empty array)
  # @param model [String]
  # @return [Hash] body suitable for +Faraday.post+ with +:json+ middleware
  def self.request_body(log, tools:, model:)
    body = { model: model, messages: log.map { |msg| message_to_h(msg) } }
    body[:tools] = tools.map(&:to_openai_schema) unless tools.empty?
    body
  end

  def self.message_to_h(msg)
    case msg.role
    when :system, :user
      { role: msg.role.to_s, content: msg.content }
    when :assistant
      h = { role: 'assistant', content: msg.content }
      h[:tool_calls] = msg.tool_calls.map { |tc| tool_call_to_h(tc) } if msg.tool_calls && !msg.tool_calls.empty?
      h
    when :tool
      { role: 'tool', content: msg.content, tool_call_id: msg.tool_call_id }
    end
  end
  private_class_method :message_to_h

  def self.tool_call_to_h(tool_call)
    {
      type: 'function',
      id: tool_call.id,
      function: {
        name: tool_call.tool.name,
        arguments: JSON.generate(tool_call.arguments)
      }
    }
  end
  private_class_method :tool_call_to_h
end
