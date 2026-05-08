# frozen_string_literal: true

require 'json'
require_relative 'tools'

# Higher-level view of a single OpenAI chat-completion response. Wraps the one
# +choice+ we expect from a non-streaming, non-+n+ request and exposes the
# fields the agent loop actually cares about.
#
# Construct via {ChatParser#parse}; do not build directly.
#
# @!attribute [r] finish_reason
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
  ToolCall = Data.define(:tool, :arguments, :id) do
    # Validate {#arguments} against the tool's parameter schema and run it.
    #
    # @return [String] observation text to feed back as the next +tool+
    #   message
    # @raise [Tool::Parameters::ValidationError] if {#arguments} does not
    #   match the tool's declared schema
    def run
      tool.run(arguments)
    end
  end
end

# Parses raw OpenAI chat-completion bodies into {ChatResponse} objects. Holds
# the list of available {Tool}s so it can resolve tool-call names; pass an
# empty array if the request did not advertise any tools.
#
# All checks are loud: any structural surprise raises +RuntimeError+ with the
# offending body included, matching the rest of this codebase.
class ChatParser
  # OpenAI's documented set; anything else is treated as a protocol error.
  KNOWN_FINISH_REASONS = %i[stop tool_calls length content_filter].freeze

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
  # @raise [RuntimeError] if the body shape is unexpected, the
  #   +finish_reason+ is unknown, +tool_calls+ is empty when
  #   +finish_reason+ is +tool_calls+, a tool-call references an unknown
  #   tool, or +function.arguments+ is not a JSON object
  def parse(body)
    raise "Expected response body to be a Hash, got #{body.class}: #{body.inspect}" unless body.is_a?(Hash)

    choices = body['choices']
    unless choices.is_a?(Array) && choices.size == 1
      raise "Expected exactly 1 choice, got #{choices&.size.inspect}: #{body}"
    end

    choice = choices[0]
    finish_reason = parse_finish_reason(choice['finish_reason'], body)

    msg = choice['message']
    raise "Missing or non-Hash message in choice: #{body}" unless msg.is_a?(Hash)

    ChatResponse.new(
      finish_reason: finish_reason,
      message: msg['content'],
      reasoning: msg['reasoning_content'],
      tool_calls: parse_tool_calls(msg['tool_calls'], finish_reason, body)
    )
  end

  private

  def parse_finish_reason(raw, body)
    raise "Missing finish_reason: #{body}" if raw.nil?

    reason = raw.to_sym
    return reason if KNOWN_FINISH_REASONS.include?(reason)

    raise "Unknown finish_reason `#{raw}` (known: #{KNOWN_FINISH_REASONS.join(', ')}): #{body}"
  end

  def parse_tool_calls(raw, finish_reason, body)
    if finish_reason == :tool_calls
      unless raw.is_a?(Array) && !raw.empty?
        raise "finish_reason is `tool_calls` but tool_calls is empty or missing: #{body}"
      end

      raw.map { |tc| parse_tool_call(tc, body) }
    else
      []
    end
  end

  def parse_tool_call(tc, body)
    raise "tool_call entry is not a Hash: #{tc.inspect} (in #{body})" unless tc.is_a?(Hash)
    raise "tool_call type is not `function`: #{tc.inspect} (in #{body})" unless tc['type'] == 'function'

    id = tc['id']
    raise "tool_call missing id: #{tc.inspect} (in #{body})" unless id.is_a?(String) && !id.empty?

    function = tc['function']
    raise "tool_call missing function block: #{tc.inspect} (in #{body})" unless function.is_a?(Hash)

    tool = resolve_tool(function['name'], tc, body)
    arguments = parse_arguments(function['arguments'], tc)

    ChatResponse::ToolCall.new(tool: tool, arguments: arguments, id: id)
  end

  def resolve_tool(name, tc, body)
    raise "tool_call function missing name: #{tc.inspect} (in #{body})" unless name.is_a?(String) && !name.empty?

    tool = @tools_by_name[name]
    return tool if tool

    known = @tools_by_name.keys.map { |n| "`#{n}`" }.join(', ')
    known = '(none)' if known.empty?
    raise "tool_call references unknown tool `#{name}` (known: #{known}): #{body}"
  end

  def parse_arguments(raw, tc)
    raise "tool_call function missing arguments string: #{tc.inspect}" unless raw.is_a?(String)

    decoded = begin
      JSON.parse(raw)
    rescue JSON::ParserError => e
      raise "tool_call arguments are not valid JSON: #{e.message} — raw: #{raw.inspect}"
    end
    return decoded if decoded.is_a?(Hash)

    raise "tool_call arguments JSON did not decode to an object: got #{decoded.class} — raw: #{raw.inspect}"
  end
end
