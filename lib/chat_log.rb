# frozen_string_literal: true

# An append-only chat history shared between the user, the assistant, and tool
# observations. Construct via {.new} (empty) and grow via the role-specific
# helpers ({#system}, {#user}, {#assistant}, {#tool}) or the generic {#add}.
# Acts as an +Enumerable+ over its {Message} entries in append order.
#
# +ChatLog+ is intentionally protocol-agnostic: it knows nothing about OpenAI
# or any other provider's wire format. The transport layer (e.g.
# {OpenAIClient}) is responsible for translating a +ChatLog+ to a request body.
class ChatLog
  # The full set of recognized message roles.
  #
  # - +:system+ — sets the assistant's behavior, persona, or task. Typically
  #   the first message; multiple system messages are allowed but unusual.
  #   Carries +content+ only.
  # - +:user+ — input from the human/operator. Carries +content+ only.
  # - +:assistant+ — output from the model. Carries free-form +content+ and/or
  #   a list of {ChatResponse::ToolCall}s in +tool_calls+ — at least one of
  #   the two must be present (a wholly-empty assistant turn is rejected).
  # - +:tool+ — observation produced by executing a tool the assistant called.
  #   Carries +content+ (the observation text) and +tool_call_id+ pointing at
  #   the +id+ of the assistant's prior +tool_calls+ entry. Must come after
  #   the assistant message that emitted that call.
  ALLOWED_ROLES = %i[system user assistant tool].freeze

  # A single entry in a {ChatLog}. Validated in the constructor: a bad
  # role/content/tool_calls/tool_call_id combination raises +ArgumentError+,
  # so any +Message+ that exists is structurally legal.
  #
  # @!attribute [r] role
  #   @return [Symbol] one of {ALLOWED_ROLES}
  # @!attribute [r] content
  #   @return [String, nil] message text. Required for +:system+, +:user+,
  #     +:tool+; optional for +:assistant+ when {#tool_calls} is non-empty
  # @!attribute [r] tool_calls
  #   @return [Array<ChatResponse::ToolCall>, nil] tool calls the assistant
  #     emitted; non-empty only when +role+ is +:assistant+
  # @!attribute [r] tool_call_id
  #   @return [String, nil] +id+ of the assistant tool-call this observation
  #     answers; present only when +role+ is +:tool+
  Message = Data.define(:role, :content, :tool_calls, :tool_call_id) do
    # @raise [ArgumentError] for any role/field combination outside the matrix
    #   documented on {ChatLog::ALLOWED_ROLES}
    def initialize(role:, content: nil, tool_calls: nil, tool_call_id: nil)
      validate!(role, content, tool_calls, tool_call_id)
      super(role: role, content: content, tool_calls: tool_calls, tool_call_id: tool_call_id)
    end

    def to_s
      s = "#{role}: #{content}"
      s += " ->#{tool_calls.join(',')}" unless tool_calls.nil? || tool_calls.empty?
      s
    end

    private

    def validate!(role, content, tool_calls, tool_call_id)
      unless ALLOWED_ROLES.include?(role)
        raise ArgumentError, "role must be one of #{ALLOWED_ROLES.inspect}, got #{role.inspect}"
      end

      case role
      when :system, :user
        check_string!(role, :content, content)
        reject_extra!(role, tool_calls: tool_calls, tool_call_id: tool_call_id)
      when :assistant
        reject_extra!(role, tool_call_id: tool_call_id)
        has_text = content.is_a?(String) && !content.empty?
        has_calls = tool_calls.is_a?(Array) && !tool_calls.empty?
        unless has_text || has_calls
          raise ArgumentError, 'assistant message must carry non-empty content or non-empty tool_calls'
        end
        if !tool_calls.nil? && !tool_calls.is_a?(Array)
          raise ArgumentError, "assistant tool_calls must be an Array, got #{tool_calls.class}"
        end
      when :tool
        check_string!(role, :content, content)
        unless tool_call_id.is_a?(String) && !tool_call_id.empty?
          raise ArgumentError, 'tool message must have a non-empty String tool_call_id'
        end
        reject_extra!(role, tool_calls: tool_calls)
      end
    end

    def check_string!(role, field, value)
      return if value.is_a?(String)

      raise ArgumentError, "#{role} message #{field} must be a String, got #{value.class}"
    end

    def reject_extra!(role, **forbidden)
      forbidden.each do |field, value|
        next if value.nil?

        raise ArgumentError, "#{role} message must not have #{field}"
      end
    end
  end

  include Enumerable

  # @return [ChatLog] empty log
  def initialize
    @messages = []
  end

  # Iterate over messages in append order.
  #
  # @yieldparam message [Message]
  # @return [Enumerator] when called without a block
  def each(&block)
    @messages.each(&block)
  end

  # @return [Integer] number of messages currently in the log
  def size
    @messages.size
  end

  # Append an arbitrary {Message}. Prefer the role-specific helpers
  # ({#system}, {#user}, {#assistant}, {#tool}) at call sites.
  #
  # @param message [Message]
  # @return [self]
  def add(message)
    raise ArgumentError, "expected ChatLog::Message, got #{message.class}" unless message.is_a?(Message)

    @messages << message
    self
  end

  # Append a +:system+ message.
  #
  # @param content [String]
  # @return [self]
  def system(content)
    add(Message.new(role: :system, content: content))
  end

  # Append a +:user+ message.
  #
  # @param content [String]
  # @return [self]
  def user(content)
    add(Message.new(role: :user, content: content))
  end

  # Append an +:assistant+ message. At least one of +content+ or +tool_calls+
  # must be present (a turn that is both empty and call-less is rejected).
  #
  # @param content [String, nil] free-form reply text
  # @param tool_calls [Array<ChatResponse::ToolCall>, nil] calls the model emitted
  # @return [self]
  def assistant(content: nil, tool_calls: nil)
    add(Message.new(role: :assistant, content: content, tool_calls: tool_calls))
  end

  # Append a +:tool+ observation.
  #
  # @param content [String] the observation text fed back to the model
  # @param tool_call_id [String] +id+ of the assistant tool-call being answered
  # @return [self]
  def tool(content, tool_call_id:)
    add(Message.new(role: :tool, content: content, tool_call_id: tool_call_id))
  end

  def to_s = @messages.join("\n")
end
