# frozen_string_literal: true

require 'json'
require 'digest'
require 'pathname'
require 'securerandom'

module Pikuri
  class Agent
    # A conversation, as a value — what {Agent#export_history} hands out and
    # {Agent#load_history!} takes back. Two encodings, one in-memory value:
    #
    #   json = agent.export_history.to_json        # self-contained, base64 inside
    #   agent.load_history!(History.parse(json))
    #
    #   dir = agent.export_history.save('/tmp/conv')  # dir/history.json + attachments/
    #   agent.load_history!(History.load(dir))
    #
    # Both round-trip to the same value, which is the property that keeps them
    # from drifting into two formats:
    #
    #   History.load(dir) == History.parse(json)   # => true
    #
    # The system prompt is *not* here — {Agent#clear_conversation} re-assembles
    # it from every extension on load, so a resumed conversation gets today's
    # prompt (a re-read +MACHINE.md+, a fresh memory persona) rather than
    # yesterday's.
    #
    # == The doors in are the validators
    #
    # {parse}, {from_h} and {load} are the only ways to build one from
    # untrusted bytes, and each raises {Error} rather than returning something
    # half-built. There is deliberately no "accepts a String or a Hash or a
    # History" convenience: one way in means one place validation could be
    # skipped, i.e. none.
    #
    # == Implementation details
    #
    # Attachment bytes are held **eagerly**, whichever door they came in
    # through — never a lazy handle to a folder that can be deleted underneath
    # it. So +==+ compares content, and a +History+ survives its folder being
    # moved. The cost is memory bounded by attachment count; a lazy reference
    # would reintroduce exactly the "the bytes changed since the model saw
    # them" failure this format exists to avoid.
    #
    # The container is one JSON object, not JSONL. Should append ever be worth
    # it, going to JSONL is a *sniff* (does the whole file parse as one
    # object?) rather than a version bump — see +design/decisions.md+ +D_history_container+.
    class History < Data.define(:version, :messages)
      # Bumped only for a change an old reader could not survive; an added
      # optional key is not one (readers ignore unknown keys). A file claiming
      # a higher version is refused, never best-effort loaded.
      CURRENT_VERSION = 1

      # Basename of the JSON written by {#save}, and read by {load}.
      HISTORY_FILE = 'history.json'

      # Subfolder {#save} writes attachment bytes into. Fixed, so
      # "in the folder" is one comparison rather than a policy.
      ATTACHMENTS_DIR = 'attachments'

      # Message roles that may appear in an exported history. +:system+ cannot:
      # the prompt is re-assembled, not replayed.
      ROLES = %w[user assistant tool].freeze

      # What a +user+-role message *is*: something the human typed
      # (+"user"+), or reference text pikuri injected on its own initiative —
      # recalled memory, a host-loaded skill, a path-activation promotion
      # (+"reference"+, what {Agent#append_reference_block} appends).
      #
      # Local only: both land on the wire as +role: :user+, and no provider is
      # told which is which. It exists so a resumed conversation can tell a
      # stale skill listing from something the human meant.
      KINDS = %w[user reference].freeze

      # Raised by every door in: a malformed record, a dangling tool result, an
      # attachment outside the folder, a version from the future.
      class Error < StandardError; end

      # One tool call the assistant asked for. +id+ is the provider's own
      # identifier and is load-bearing — the +tool+ message answering this call
      # repeats it, and providers reject a pair that does not match.
      #
      # +display_name+ and +argument+ are the chrome's display line for the call
      # (+"Write"+ / +"lib/foo.rb"+) — local to pikuri like {Message#id}, so no
      # provider ever sees them. They are stored because a later wiring may no
      # longer have the tool that composed them — a removed extension, a renamed
      # MCP server — and +nil+ (a pre-summary file) falls back to
      # {Pikuri::Tool.display_name_for} / {Pikuri::Tool.describe_arguments}.
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
      # host's context readout can be reseeded after a load — nothing on the
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
        # @param role [String] one of {ROLES}
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
        #   stored because it was computed from structure the +content+ no
        #   longer holds, so nothing can recompute it on load. +nil+ (a
        #   pre-summary file) falls back to {Pikuri::Tool.describe_content}.
        def initialize(id:, role:, content:, kind: 'user', attachments: [], tool_calls: [],
                       tool_call_id: nil, model_id: nil, thinking: nil, tokens: nil, summary: nil)
          super
        end

        # @return [Boolean] whether this message asked for tools.
        def tool_call? = !tool_calls.empty?

        # Snapshot a live +RubyLLM::Message+. Attachment bytes are read *now*
        # — the file a tool showed the model may be gone or changed by the
        # time anyone loads this back.
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
            tool_calls: (msg.tool_calls || {}).values.map do |c|
              lines = tool_call_lines[c.id] || {}
              ToolCall.new(id: c.id, name: c.name, arguments: c.arguments || {},
                           display_name: lines[:display_name], argument: lines[:argument])
            end,
            tool_call_id: msg.tool_call_id,
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
        #   writes it. See +design/decisions.md+ +D_thinking_block_replay+.
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

      class << self
        # Parse the self-contained JSON form.
        #
        #   History.parse(File.read('conv.json'))
        #
        # @param json [String] what {#to_json} produced.
        # @return [History]
        # @raise [Error] on malformed JSON, a bad record, a future version, or
        #   an attachment stored as a file — a String has no folder to resolve
        #   one against, so that case names {load} rather than guessing.
        def parse(json)
          raw = begin
            JSON.parse(json)
          rescue JSON::ParserError => e
            raise Error, "history is not valid JSON: #{e.message}"
          end
          from_h(raw)
        end

        # Read a folder written by {#save}.
        #
        # @param dir [String, Pathname] the folder holding {HISTORY_FILE}.
        # @return [History]
        # @raise [Error] as {from_h}, plus a missing, unreadable, or
        #   digest-mismatched attachment.
        def load(dir)
          dir = Pathname(dir)
          file = dir / HISTORY_FILE
          raise Error, "no #{HISTORY_FILE} in #{dir}" unless file.file?

          raw = begin
            JSON.parse(file.read)
          rescue JSON::ParserError => e
            raise Error, "#{file} is not valid JSON: #{e.message}"
          end
          from_h(raw, dir: dir)
        end

        # Validate a plain Hash — the shared gate {parse} and {load} both run
        # through, and the only place a record's shape is checked.
        #
        # Unknown *keys* are ignored, so a file written by a newer pikuri
        # still loads; malformed *known* keys raise. That asymmetry is the
        # whole forward-compatibility story, and it is why {CURRENT_VERSION}
        # is expected to stay +1+.
        #
        # @param raw [Hash] parsed JSON, String keys.
        # @param dir [Pathname, nil] folder to resolve file-backed attachments
        #   against; +nil+ refuses them.
        # @return [History]
        # @raise [Error] on a non-Hash, a version above {CURRENT_VERSION}, a
        #   message with a bad role/kind/id, a duplicate id, or a +tool+
        #   message whose +tool_call_id+ no preceding assistant message issued.
        def from_h(raw, dir: nil)
          raise Error, "expected a Hash, got #{raw.class}" unless raw.is_a?(Hash)

          version = raw['version']
          raise Error, "missing version (expected #{CURRENT_VERSION})" if version.nil?
          if version.is_a?(Integer) && version > CURRENT_VERSION
            raise Error, "history version #{version} is newer than this pikuri understands " \
                         "(#{CURRENT_VERSION}); upgrade pikuri to read it"
          end
          raise Error, "version must be #{CURRENT_VERSION}, got #{version.inspect}" unless version == CURRENT_VERSION

          messages = raw['messages']
          raise Error, "messages must be an Array, got #{messages.class}" unless messages.is_a?(Array)

          built = messages.each_with_index.map { |m, i| message_from_h(m, i, dir) }
          check_ids!(built)
          check_tool_pairing!(built)
          new(version: CURRENT_VERSION, messages: built)
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
        def mint_id
          MINT_LOCK.synchronize do
            @counter = ((@counter || -1) + 1) & 0xffff
            format('%012x%04x%s', (Time.now.to_f * 1000).to_i, @counter, SecureRandom.hex(3))
          end
        end

        private

        def message_from_h(raw, index, dir)
          raise Error, "message #{index}: expected a Hash, got #{raw.class}" unless raw.is_a?(Hash)

          role = raw['role']
          raise Error, "message #{index}: role must be one of #{ROLES.join('/')}, got #{role.inspect}" unless
            ROLES.include?(role)

          # Absent kind reads as "user": additive fields must not break an
          # older file, and this is the only field with a sensible default.
          kind = raw['kind'] || 'user'
          raise Error, "message #{index}: kind must be one of #{KINDS.join('/')}, got #{kind.inspect}" unless
            KINDS.include?(kind)

          id = raw['id']
          raise Error, "message #{index}: id must be a non-empty String, got #{id.inspect}" unless
            id.is_a?(String) && !id.empty?

          tool_call_id = raw['tool_call_id']
          if role == 'tool' && !(tool_call_id.is_a?(String) && !tool_call_id.empty?)
            raise Error, "message #{index} (#{id}): a tool message needs a tool_call_id, got #{tool_call_id.inspect}"
          end
          if role != 'tool' && !tool_call_id.nil?
            raise Error, "message #{index} (#{id}): only a tool message may carry a tool_call_id"
          end

          Message.new(
            id: id, role: role, kind: kind,
            content: string_field(raw['content'], index, id, 'content'),
            attachments: (raw['attachments'] || []).map { |a| attachment_from_h(a, index, id, dir) },
            tool_calls: (raw['tool_calls'] || []).map { |t| tool_call_from_h(t, index, id) },
            tool_call_id: tool_call_id,
            model_id: raw['model_id'],
            thinking: thinking_from_h(raw['thinking'], index, id),
            tokens: tokens_from_h(raw['tokens'], index, id),
            summary: display_string(raw['summary'], index, id, 'summary')
          )
        end

        def string_field(value, index, id, name)
          return value if value.is_a?(String)
          return '' if value.nil?

          raise Error, "message #{index} (#{id}): #{name} must be a String, got #{value.class}"
        end

        def tool_call_from_h(raw, index, id)
          raise Error, "message #{index} (#{id}): each tool_call must be a Hash" unless raw.is_a?(Hash)

          call_id = raw['id']
          raise Error, "message #{index} (#{id}): a tool_call needs a non-empty id" unless
            call_id.is_a?(String) && !call_id.empty?
          raise Error, "message #{index} (#{id}): tool_call #{call_id} needs a name" unless raw['name'].is_a?(String)

          args = raw['arguments'] || {}
          raise Error, "message #{index} (#{id}): tool_call #{call_id} arguments must be a Hash" unless args.is_a?(Hash)

          ToolCall.new(id: call_id, name: raw['name'], arguments: args,
                       display_name: display_string(raw['display_name'], index, id, 'display_name'),
                       argument: display_string(raw['argument'], index, id, 'argument'))
        end

        # A stored display string: absent reads as +nil+ (an older file, or a
        # wiring that had no tool to ask), present must be a String.
        def display_string(value, index, id, name)
          return nil if value.nil?
          return value if value.is_a?(String)

          raise Error, "message #{index} (#{id}): #{name} must be a String, got #{value.class}"
        end

        def thinking_from_h(raw, index, id)
          return nil if raw.nil?
          raise Error, "message #{index} (#{id}): thinking must be a Hash" unless raw.is_a?(Hash)

          Thinking.new(text: raw['text'], signature: raw['signature'])
        end

        def tokens_from_h(raw, index, id)
          return nil if raw.nil?
          raise Error, "message #{index} (#{id}): tokens must be a Hash" unless raw.is_a?(Hash)

          Tokens.new(
            input: raw['input'], output: raw['output'], cached: raw['cached'],
            cache_creation: raw['cache_creation'], thinking: raw['thinking']
          )
        end

        def attachment_from_h(raw, index, id, dir)
          raise Error, "message #{index} (#{id}): each attachment must be a Hash" unless raw.is_a?(Hash)

          filename = raw['filename'].to_s
          bytes =
            case raw['kind']
            when 'inline' then decode_inline(raw['bytes'], index, id)
            when 'file' then read_confined(dir, raw['file'], index, id)
            else raise Error, "message #{index} (#{id}): attachment kind must be inline or file, " \
                              "got #{raw['kind'].inspect}"
            end

          Pikuri::Attachment.new(mime: raw['mime'], filename: filename, bytes: bytes)
        end

        def decode_inline(data, index, id)
          raise Error, "message #{index} (#{id}): inline attachment needs base64 bytes" unless data.is_a?(String)

          data.unpack1('m0')
        rescue ArgumentError => e
          raise Error, "message #{index} (#{id}): attachment base64 is malformed: #{e.message}"
        end

        # Read one attachment, refusing anything that is not a plain file
        # directly inside +dir/attachments+.
        #
        # The comparison is on the **resolved** path, not the string: a file
        # sitting in the folder may itself be a symlink to +~/.ssh/id_ed25519+,
        # which every textual check passes. That is the case this method
        # exists for.
        def read_confined(dir, name, index, id)
          where = "message #{index} (#{id})"
          if dir.nil?
            raise Error, "#{where}: this history references the external attachment #{name.inspect}; " \
                         'use History.load(dir) rather than History.parse'
          end
          raise Error, "#{where}: attachment file must be a String" unless name.is_a?(String)
          unless !name.empty? && name == File.basename(name) && !name.start_with?('.')
            raise Error, "#{where}: attachment file #{name.inspect} must be a bare filename"
          end

          root = dir / ATTACHMENTS_DIR
          path = root / name
          raise Error, "#{where}: attachment #{name.inspect} is missing from #{root}" unless path.file?

          real = path.realpath
          unless real.dirname == root.realpath
            raise Error, "#{where}: attachment #{name.inspect} resolves to #{real}, outside #{root}"
          end

          bytes = real.binread
          expected = name[/\A[0-9a-f]{10}/]
          if expected && !Digest::SHA256.hexdigest(bytes).start_with?(expected)
            raise Error, "#{where}: attachment #{name.inspect} does not match its content digest"
          end

          bytes
        end

        def check_ids!(messages)
          seen = {}
          messages.each_with_index do |m, i|
            if (first = seen[m.id])
              raise Error, "message #{i}: duplicate id #{m.id} (already used by message #{first})"
            end

            seen[m.id] = i
          end
        end

        # Refuse a tool result nothing asked for, and one answered twice.
        #
        # The mirror case — a call with *no* result — is deliberately legal
        # here: that is what a process killed mid-batch leaves behind, and
        # {Agent#load_history!} repairs it by synthesizing an interrupted
        # result. Refusing it would make the crash case the one thing that
        # cannot be loaded.
        def check_tool_pairing!(messages)
          issued = {}
          answered = {}
          messages.each_with_index do |m, i|
            m.tool_calls.each { |c| issued[c.id] = i }
            next unless m.role == 'tool'

            unless issued.key?(m.tool_call_id)
              raise Error, "message #{i} (#{m.id}): tool_call_id #{m.tool_call_id} " \
                           'was never issued by a preceding assistant message'
            end
            if (prev = answered[m.tool_call_id])
              raise Error, "message #{i} (#{m.id}): tool_call_id #{m.tool_call_id} " \
                           "was already answered by message #{prev}"
            end

            answered[m.tool_call_id] = i
          end
        end
      end

      MINT_LOCK = Mutex.new
      private_constant :MINT_LOCK

      # @param version [Integer] must be {CURRENT_VERSION}; defaulted so
      #   callers building one in Ruby never restate it.
      # @param messages [Array<Message>]
      def initialize(version: CURRENT_VERSION, messages: [])
        super
      end

      # The self-contained Hash: attachments inline, as base64.
      #
      # @param inline_attachments [Boolean] +false+ renders each attachment as
      #   a reference to its {Pikuri::Attachment#stored_name}, which only {#save}
      #   wants — the bytes then live in the folder, not the Hash.
      # @return [Hash{String => Object}] JSON-safe, String keys.
      def to_h(inline_attachments: true)
        {
          'version' => version,
          'messages' => messages.map { |m| message_to_h(m, inline_attachments) }
        }
      end

      # @return [String] pretty-printed {#to_h}, so a stored conversation stays
      #   readable and diffs a turn at a time.
      def to_json(*_args)
        JSON.pretty_generate(to_h)
      end

      # Write +dir/history.json+ plus +dir/attachments/+, creating the folder if
      # needed.
      #
      #   agent.export_history.save('~/conversations/2026-08-27-abc')
      #
      # Attachments are written **first**: +history.json+ is the commit point,
      # so an interrupted save leaves unreferenced bytes (harmless) rather than
      # a reference to bytes that are not there.
      #
      # Never deletes. An attachment the history no longer references simply
      # stays — pikuri writes into this folder but does not own everything in
      # it, and removing a file a human put there is a worse failure than an
      # orphan. Re-saving is idempotent: a content-addressed name that already
      # exists is skipped after one +stat+, so cost tracks the history rather
      # than the folder.
      #
      # @param dir [String, Pathname] destination; created if absent.
      # @return [Pathname] +dir+, so a caller can chain.
      def save(dir)
        dir = Pathname(dir).expand_path
        attachments = messages.flat_map(&:attachments)

        unless attachments.empty?
          root = dir / ATTACHMENTS_DIR
          root.mkpath
          attachments.each do |a|
            path = root / a.stored_name
            atomic_write(path, a.bytes) unless path.exist?
          end
        end

        dir.mkpath
        atomic_write(dir / HISTORY_FILE, JSON.pretty_generate(to_h(inline_attachments: false)))
        dir
      end

      # A copy in which every tool call has an answer, synthesizing
      # {INTERRUPTED_RESULT} for any the recorded conversation left hanging —
      # what a process killed mid-batch leaves behind.
      #
      # Providers reject an assistant +tool_use+ with no matching result, so
      # this has to happen before the history goes back into a chat. It runs
      # at *load*, never at export: the file stays a faithful record of what
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

      # A copy in which reasoning left inline in an assistant turn's content
      # moves to its {Thinking}, the split a live reply gets:
      #
      #   content: "<think>hmm</think>\nHi!"  # => content: "Hi!", thinking.text: "hmm"
      #
      # A server that keeps reasoning in +content+ wrote such turns while
      # pikuri did not split them; replayed as is, the reasoning reaches the
      # model as answer text on every turn. Like {#repair_interrupted_tool_calls}
      # it runs at load, so the file stays as written. Keyed on the tag, not on
      # when the file was written: the format has no version to key on, and
      # a clean history has no tag to find. See +design/decisions.md+
      # +D_history_load_repairs+.
      #
      # @return [History] +self+ when no turn holds a tag.
      def lift_inline_thinking
        return self unless messages.any? { |m| inline_thinking?(m) }

        with(messages: messages.map { |m| inline_thinking?(m) ? lift_thinking(m) : m })
      end

      # Observation synthesized for a tool call whose result never arrived.
      INTERRUPTED_RESULT = '[Tool execution was interrupted]'

      private

      # Same test as the live {Agent#split_inline_thinking!}.
      def inline_thinking?(msg)
        msg.role == 'assistant' && msg.content.include?(ThinkTagSplitter::OPEN)
      end

      def lift_thinking(msg)
        content, inline = ThinkTagSplitter.split(msg.content)
        text = [msg.thinking&.text, inline].compact.reject(&:empty?).join("\n")
        msg.with(content: content,
                 thinking: text.empty? ? msg.thinking : Thinking.new(text: text, signature: msg.thinking&.signature))
      end

      def message_to_h(msg, inline)
        h = {
          'id' => msg.id,
          'role' => msg.role,
          'kind' => msg.kind,
          'content' => msg.content
        }
        h['attachments'] = msg.attachments.map { |a| attachment_to_h(a, inline) } unless msg.attachments.empty?
        h['tool_calls'] = msg.tool_calls.map { |c| tool_call_to_h(c) } unless msg.tool_calls.empty?
        h['tool_call_id'] = msg.tool_call_id if msg.tool_call_id
        h['summary'] = msg.summary if msg.summary
        h['model_id'] = msg.model_id if msg.model_id
        h['thinking'] = compact_h(msg.thinking) if msg.thinking
        h['tokens'] = compact_h(msg.tokens) if msg.tokens
        h
      end

      # Drops an absent display string rather than writing +null+, so a file
      # written before summaries existed and one written by a wiring that had
      # no tool to ask are the same bytes.
      def tool_call_to_h(call)
        h = { 'id' => call.id, 'name' => call.name, 'arguments' => call.arguments }
        h['display_name'] = call.display_name if call.display_name
        h['argument'] = call.argument if call.argument
        h
      end

      # Every {Pikuri::Attachment} field, mirrored by +attachment_from_h+; a
      # new field belongs in both.
      def attachment_to_h(att, inline)
        base = { 'mime' => att.mime, 'filename' => att.filename }
        if inline
          base.merge('kind' => 'inline', 'bytes' => [att.bytes].pack('m0'))
        else
          base.merge('kind' => 'file', 'file' => att.stored_name)
        end
      end

      def compact_h(value)
        value.to_h.compact.transform_keys(&:to_s)
      end

      # Write via a sibling temp file and rename, so a reader never sees a
      # half-written file and a crash cannot leave one.
      def atomic_write(path, content)
        tmp = path.dirname / ".#{path.basename}.tmp"
        tmp.binwrite(content)
        tmp.rename(path.to_s)
      end
    end
  end
end
