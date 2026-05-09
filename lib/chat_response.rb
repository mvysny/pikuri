# frozen_string_literal: true

require 'json'
require 'json_schemer'
require_relative 'tool'

# Higher-level view of a single OpenAI chat-completion response. Wraps the one
# +choice+ we expect from a non-streaming, non-+n+ request and exposes the
# fields the agent loop actually cares about.
#
# Construct via {ChatParser#parse}; do not build directly.
#
# @!attribute [r] finish_reason
#   Why the model stopped generating. Mirrors OpenAI's documented set,
#   symbolized:
#
#   - +:stop+ — natural end of generation: the model emitted its end-of-turn
#     token (or hit a configured stop sequence). {#message} holds the final
#     assistant text and {#tool_calls} is empty.
#   - +:tool_calls+ — the model wants the host to execute one or more tools
#     before continuing. {#tool_calls} is non-empty; {#message} is usually
#     +""+ or +nil+. The agent loop must run each call and feed the
#     observations back as +tool+ messages on the next turn.
#   - +:length+ — generation was cut off because it hit the +max_tokens+
#     budget (or the model's context limit). The response is partial; any
#     tool call in flight is likely truncated and unsafe to execute.
#   - +:content_filter+ — the backend's safety/content filter aborted the
#     generation. Output, if any, is incomplete and should not be trusted as
#     a finished answer.
#   @return [Symbol] one of +:stop+, +:tool_calls+, +:length+,
#     +:content_filter+
# @!attribute [r] message
#   @return [String, nil] assistant text. Always a +String+ for +:stop+;
#     may be +""+ or +nil+ when {#finish_reason} is +:tool_calls+
# @!attribute [r] reasoning
#   @return [String, nil] +reasoning_content+ from thinking models, or +nil+
# @!attribute [r] tool_calls
#   @return [Array<ChatResponse::ToolCall>] non-empty iff +finish_reason+ is
#     +:tool_calls+; otherwise +[]+
ChatResponse = Data.define(:finish_reason, :message, :reasoning, :tool_calls)

class ChatResponse
  # A single resolved tool call from the assistant: the {Tool} the LLM picked
  # (resolved against the parser's tool list), the JSON-decoded argument hash,
  # and the OpenAI call +id+ — needed to thread the tool's observation back
  # in the next turn's +tool+ message.
  #
  # @!attribute [r] tool
  #   @return [Tool] resolved by name against the {ChatParser}'s tool list
  # @!attribute [r] arguments
  #   @return [Hash] arguments JSON-decoded from
  #     +function.arguments+; not yet validated against {Tool#parameters}
  # @!attribute [r] id
  #   @return [String] OpenAI tool-call id, e.g. +"call_abc123"+
  class ToolCall < Data.define(:tool, :arguments, :id)
    # Validate {#arguments} against the tool's parameter schema and run it.
    #
    # @return [String] observation text to feed back as the next +tool+
    #   message
    # @raise [Tool::Parameters::ValidationError] if {#arguments} does not
    #   match the tool's declared schema
    def run
      result = tool.run(arguments)
      raise unless result.is_a? String
      result
    end

    def to_s = "#{tool.name}(#{arguments.map { |k, v| "#{k}=#{v}" } .join(",")})"
  end
end

# Parses raw OpenAI chat-completion bodies into {ChatResponse} objects. Holds
# the list of available {Tool}s so it can resolve tool-call names; pass an
# empty array if the request did not advertise any tools.
#
# Body shape is validated against the JSON Schema vendored at
# +schemas/chat_completion_response.json+; anything past that point (parsing
# the JSON-string +function.arguments+, resolving tool names) is checked
# imperatively. All checks are loud: any structural surprise raises
# +RuntimeError+ with the offending body included.
class ChatParser
  SCHEMA = JSONSchemer.schema(
    JSON.parse(File.read(File.expand_path('../schemas/chat_completion_response.json', __dir__)))
  )

  # @param tools [Array<Tool>] tools advertised on the request; used to
  #   resolve +function.name+ in tool-call responses
  # @return [ChatParser]
  def initialize(tools:)
    @tools_by_name = tools.each_with_object({}) { |t, h| h[t.name] = t }.freeze
  end

  # Convert a decoded chat-completion body into a {ChatResponse}.
  #
  # @param body [Hash] JSON-decoded response body (e.g. Faraday's
  #   +response.body+ when +:json+ middleware is enabled)
  # @return [ChatResponse]
  # @raise [RuntimeError] if the body fails JSON Schema validation, a
  #   tool-call references an unknown tool, or +function.arguments+ is not a
  #   JSON object
  def parse(body)
    validate_schema!(body)

    choice = body['choices'][0]
    msg = choice['message']
    finish_reason = choice['finish_reason'].to_sym

    ChatResponse.new(
      finish_reason: finish_reason,
      message: msg['content'],
      reasoning: msg['reasoning_content'],
      tool_calls: finish_reason == :tool_calls ? msg['tool_calls'].map { |tc| parse_tool_call(tc) } : []
    )
  end

  private

  def validate_schema!(body)
    errors = SCHEMA.validate(body).to_a
    return if errors.empty?

    formatted = errors.map { |e| "  - #{e['data_pointer'].empty? ? '<root>' : e['data_pointer']}: #{e['error']}" }
    raise "Invalid chat completion response:\n#{formatted.join("\n")}\nBody: #{body.inspect}"
  end

  def parse_tool_call(tc)
    function = tc['function']
    ChatResponse::ToolCall.new(
      tool: resolve_tool(function['name']),
      arguments: parse_arguments(function['arguments']),
      id: tc['id']
    )
  end

  def resolve_tool(name)
    tool = @tools_by_name[name]
    return tool if tool

    known = @tools_by_name.keys.map { |n| "`#{n}`" }.join(', ')
    known = '(none)' if known.empty?
    raise "tool_call references unknown tool `#{name}` (known: #{known})"
  end

  def parse_arguments(raw)
    decoded = begin
      JSON.parse(raw)
    rescue JSON::ParserError => e
      raise "tool_call arguments are not valid JSON: #{e.message} — raw: #{raw.inspect}"
    end
    return decoded if decoded.is_a?(Hash)

    raise "tool_call arguments JSON did not decode to an object: got #{decoded.class} — raw: #{raw.inspect}"
  end
end
