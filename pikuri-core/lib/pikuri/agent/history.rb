# frozen_string_literal: true

require 'securerandom'

module Pikuri
  class Agent
    # A conversation, as a value — what {Agent#export_history} hands out and
    # +Agent.new(history:)+ resumes:
    #
    #   history = agent.export_history
    #   agent.close
    #   Agent.new(transport: t, system_prompt: p, history: history)
    #
    # The system prompt is *not* here — the resuming agent assembles its own
    # from every extension, so a resumed conversation gets today's
    # prompt (a re-read +MACHINE.md+, a fresh memory persona) rather than
    # yesterday's.
    #
    # pikuri never writes one to disk nor reads one back: storing a
    # conversation, and validating stored bytes on the way in, is the host's.
    #
    # == Implementation details
    #
    # Attachment bytes are held **eagerly** as {Pikuri::Attachment}s, never a
    # lazy handle to a file that can change underneath — so +==+ compares
    # content, and the history is what the model saw.
    class History < Data.define(:messages)
      # What a +user+-role message *is*: something the human typed
      # (+"user"+), or reference text pikuri injected on its own initiative —
      # recalled memory, a host-loaded skill, a path-activation promotion
      # (+"reference"+, what {Agent#append_reference_block} appends).
      #
      # Local only: both land on the wire as +role: :user+, and no provider is
      # told which is which. It exists so a resumed conversation can tell a
      # stale skill listing from something the human meant.
      KINDS = %w[user reference].freeze

      # One tool call the assistant asked for. +id+ is the provider's own
      # identifier and is load-bearing — the +tool+ message answering this call
      # repeats it, and providers reject a pair that does not match.
      #
      # +display_name+ and +argument+ are the chrome's display line for the call
      # (+"Write"+ / +"lib/foo.rb"+) — local to pikuri like {Message#id}, so no
      # provider ever sees them. They are kept because a later wiring may no
      # longer have the tool that composed them — a removed extension, a renamed
      # MCP server — and +nil+ falls back to {Pikuri::Tool.display_name_for} /
      # {Pikuri::Tool.describe_arguments}.
      ToolCall = Data.define(:id, :name, :arguments, :display_name, :argument) do
        # @param id [String] the provider's tool-call id
        # @param name [String] the tool name
        # @param arguments [Hash] arguments as the model sent them
        # @param display_name [String, nil] see {Pikuri::Tool#display_name}
        # @param argument [String, nil] see {Pikuri::Tool#describe_call}
        def initialize(id:, name:, arguments: {}, display_name: nil, argument: nil)
          super
        end
      end

      # An assistant reasoning block, as the provider reported it.
      #
      # The two fields are not symmetric, and which one carries the substance
      # flips by provider: on Anthropic +signature+ is the full reasoning,
      # encrypted, and +text+ a summary that is empty by default; on an
      # OpenAI-compatible server +text+ is the reasoning itself and
      # +signature+ is usually absent. So the whole block, never one field, is
      # what {Agent} withholds from a model that did not produce it — see
      # +design/decisions.md+ +D_thinking_block_replay+.
      Thinking = Data.define(:text, :signature)

      # Per-message token usage, as the provider reported it. Carried so a
      # host's context readout can be reseeded after a resume — nothing on the
      # wire needs it.
      Tokens = Data.define(:input, :output, :cached, :cache_creation, :thinking)

      # One message. +id+ and +kind+ are pikuri's own and never reach a
      # provider; everything else is what the model saw.
      #
      # +content+ is always a String (empty on a pure tool-call turn, which is
      # what ruby_llm stores); anything the model was *shown* beyond text is an
      # {Pikuri::Attachment} in +attachments+.
      Message = Data.define(
        :id, :role, :kind, :content, :attachments,
        :tool_calls, :tool_call_id, :model_id, :thinking, :tokens, :summary
      ) do
        # @param id [String] see {History.mint_id}
        # @param role [String] +"user"+, +"assistant"+ or +"tool"+; never
        #   +"system"+ — the prompt is re-assembled, not replayed
        # @param kind [String] one of {KINDS}; defaults to +"user"+
        # @param content [String] the text the model saw; +""+ is legal
        # @param attachments [Array<Pikuri::Attachment>]
        # @param tool_calls [Array<ToolCall>] empty unless the assistant asked
        #   for tools
        # @param tool_call_id [String, nil] set exactly on a +tool+ message
        # @param model_id [String, nil] which model produced this
        # @param thinking [Thinking, nil]
        # @param tokens [Tokens, nil]
        # @param summary [String, nil] a +tool+ message's display line
        #   (+"Returned 23 search results"+) — local to pikuri like {#id}, and
        #   kept because it was computed from structure the +content+ no
        #   longer holds, so nothing can recompute it on resume. +nil+ falls
        #   back to {Pikuri::Tool.describe_content}.
        def initialize(id:, role:, content:, kind: 'user', attachments: [], tool_calls: [],
                       tool_call_id: nil, model_id: nil, thinking: nil, tokens: nil, summary: nil)
          super
        end

        # @return [Boolean] whether this message asked for tools.
        def tool_call? = !tool_calls.empty?

        # Snapshot a live +RubyLLM::Message+. Attachment bytes are read *now*
        # — the file a tool showed the model may be gone or changed by the
        # time anyone resumes this.
        #
        # @param msg [RubyLLM::Message] must not be +role: :system+.
        # @param id [String] see {History.mint_id}.
        # @param kind [String] one of {KINDS}.
        # @param summary [String, nil] see {Message#summary}.
        # @param tool_call_lines [Hash{String=>Hash}] display strings per call
        #   id, +{id => {display_name:, argument:}}+ — what {Agent} recorded as
        #   each call went out; an id it has nothing for stores +nil+s.
        # @return [Message]
        def self.from_ruby_llm(msg, id:, kind: 'user', summary: nil, tool_call_lines: {})
          attachments = msg.attachments.map { |a| Pikuri::Attachment.from_ruby_llm(a) }
          t = msg.tokens
          new(
            id: id, role: msg.role.to_s, kind: kind, content: msg.content.to_s, attachments: attachments,
            summary: summary,
            # The server's call ids, not the ones ruby_llm mints per chat: a
            # restored call replays its +id+ on the wire, and anything else
            # would change the request bytes. See +D_history_wire_call_ids+.
            tool_calls: (msg.tool_calls || {}).values.map do |c|
              lines = tool_call_lines[c.provider_call_id] || {}
              ToolCall.new(id: c.provider_call_id, name: c.name, arguments: c.arguments || {},
                           display_name: lines[:display_name], argument: lines[:argument])
            end,
            tool_call_id: msg.provider_call_id,
            model_id: msg.model,
            thinking: msg.thinking && Thinking.new(text: msg.thinking.text, signature: msg.thinking.signature),
            # ruby_llm gives every message a Tokens, all-nil where nothing was
            # counted; +nil+ keeps "no usage" out of the export.
            tokens: (Tokens.new(input: t.input, output: t.output, cached: t.cache_read,
                               cache_creation: t.cache_write, thinking: t.thinking) if t.to_h.any?)
          )
        end

        # Rebuild the +RubyLLM::Message+ this was taken from.
        #
        # @param keep_thinking [Boolean] +false+ replays the turn without its
        #   {Thinking} block at all — what {Agent} passes for a turn some
        #   *other* model produced, since a thinking block lands in a slot the
        #   receiving model reads as its own scratchpad. Dropped from the
        #   *message*, not from the record: {Agent#export_history} still
        #   carries it. See +design/decisions.md+ +D_thinking_block_replay+.
        # @return [RubyLLM::Message]
        def to_ruby_llm(keep_thinking: true)
          calls = tool_calls.to_h do |c|
            [c.id, RubyLLM::ToolCall.new(id: c.id, name: c.name, arguments: c.arguments)]
          end
          replayed = thinking if keep_thinking
          RubyLLM::Message.new(
            role: role.to_sym,
            # An attachment-only user turn went out with no text part
            # ({Agent#run_loop}); +""+ would replay as an empty one, which
            # Anthropic refuses.
            content: content.empty? && !attachments.empty? ? nil : content,
            attachments: attachments.map(&:to_ruby_llm),
            tool_calls: calls.empty? ? nil : calls,
            tool_call_id: tool_call_id,
            model: model_id,
            thinking: replayed && RubyLLM::Thinking.build(
              text: replayed.text, signature: replayed.signature
            ),
            tokens: tokens && RubyLLM::Tokens.new(input: tokens.input, output: tokens.output, cache_read: tokens.cached,
                                                  cache_write: tokens.cache_creation, thinking: tokens.thinking)
          )
        end
      end

      # A fresh message id: lexicographically sortable, so ordering falls out
      # of the id itself and a future tree format inherits identity for free.
      #
      #   History.mint_id   # => "0198c4f1a2b30001f3c9a2"
      #
      # Not a wire value — no provider is ever shown one.
      #
      # @return [String] 22 hex chars: 12 of millisecond timestamp, 4 of
      #   per-process counter (so two ids minted in one millisecond still
      #   sort), 6 random.
      def self.mint_id
        MINT_LOCK.synchronize do
          @counter = ((@counter || -1) + 1) & 0xffff
          format('%012x%04x%s', (Time.now.to_f * 1000).to_i, @counter, SecureRandom.hex(3))
        end
      end

      MINT_LOCK = Mutex.new
      private_constant :MINT_LOCK

      # @param messages [Array<Message>]
      def initialize(messages: [])
        super
      end

      # A copy in which every tool call has an answer, synthesizing
      # {INTERRUPTED_RESULT} for any the recorded conversation left hanging —
      # what a process killed mid-batch leaves behind.
      #
      # Providers reject an assistant +tool_use+ with no matching result, so
      # this has to happen before the history goes back into a chat. It runs
      # on resume, never at export: the record stays faithful to what
      # happened, and the repair is applied on the way back in.
      #
      # Telling the model "you asked, it did not finish" beats dropping the
      # assistant turn, which would erase that it ever decided to call the
      # tool and leave it to re-derive the decision from nothing.
      #
      # @return [History] +self+ when nothing was dangling.
      def repair_interrupted_tool_calls
        out = []
        pending = []
        repaired = false
        messages.each_with_index do |m, i|
          # Hold synthetics until the batch's real results have gone by, so
          # the answering run stays contiguous and in the order it happened.
          unless pending.empty? || m.role == 'tool'
            out.concat(pending)
            pending = []
          end
          out << m
          next unless m.tool_call?

          answered = messages[(i + 1)..].take_while { |n| n.role == 'tool' }.map(&:tool_call_id)
          pending = m.tool_calls.reject { |c| answered.include?(c.id) }.map do |call|
            repaired = true
            Message.new(id: History.mint_id, role: 'tool', tool_call_id: call.id,
                        content: INTERRUPTED_RESULT, summary: INTERRUPTED_SUMMARY)
          end
        end
        out.concat(pending)
        repaired ? with(messages: out) : self
      end

      # Observation synthesized for a tool call whose result never arrived.
      INTERRUPTED_RESULT = '[Tool execution was interrupted]'
    end
  end
end
