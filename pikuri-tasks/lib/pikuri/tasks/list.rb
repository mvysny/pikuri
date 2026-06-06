# frozen_string_literal: true

module Pikuri
  module Tasks
    # Raised by {List#add} when a new item's +content+ already appears
    # in the list. Items are addressed by {Item#id}, so duplicates
    # would not be ambiguous — they are rejected because a duplicate
    # is almost always an LLM mistake (re-sending an already-captured
    # plan), and catching it early keeps the list coherent. The
    # exception carries the offending content string so the tool layer
    # can surface it verbatim in the +"Error: ..."+ observation.
    class DuplicateItem < StandardError; end

    # Raised by {List#set_status} and {List#delete} when no item with
    # the given +id+ exists. The three mutation tools rescue this and
    # report +"Error: no such task id: <id>"+ plus the current list
    # render, so the LLM can pick the right id on the next turn.
    class ItemNotFound < StandardError; end

    # Allowed values for {Item#status}. Kept deliberately small — three
    # states match the workflow the prompt advertises (pending → in_progress
    # → completed) without inviting a +cancelled+ vs +deleted+ debate.
    # +task_delete+ removes items outright rather than introducing a
    # fourth status.
    STATUSES = %w[pending in_progress completed].freeze

    # One row in a {List}. +id+ is the numeric identifier the mutation
    # tools address the item by (assigned by {List#add}, never reused —
    # see there); +content+ is the LLM-visible task text; +status+ is
    # one of {STATUSES}.
    Item = Data.define(:id, :content, :status)

    # An in-memory ordered list of {Item}s, scoped to a single
    # {Pikuri::Agent}. Held inside {Extension} and captured by closure
    # into the +execute+ block of each of the four task tool classes,
    # so every mutation hits the same instance.
    #
    # == Concurrency
    #
    # The list is confined to the agent's thread: the agent loop is
    # single-threaded with respect to tool calls (ruby_llm dispatches
    # them sequentially), so no locking. Other threads (e.g. a web UI
    # rendering the list) must not touch a +List+ directly — they
    # consume the {ListChanged} events {Extension#bind} wires onto
    # the listener stream, whose +items+ payload is an immutable
    # snapshot safe to hand across threads. A future
    # parallel-tool-execution feature would need a +Mutex+ here.
    #
    # == Persistence
    #
    # None. The list is dropped when the +Agent+ is garbage-collected.
    # That matches the gem's stated scope: "in-memory only, no
    # session-state-on-disk."
    class List
      # @return [List]
      def initialize
        @items = []
        @next_id = 1
        @on_change = nil
      end

      # Optional zero-argument hook invoked after every successful
      # mutation ({#add} / {#set_status} / {#delete}) — not on failed
      # ones (a raise means nothing changed). Set by {Extension#bind}
      # to emit a {ListChanged} onto the agent's listener stream;
      # +nil+ (the default) disables notification. Runs on the
      # mutating (agent) thread, synchronously inside the mutation
      # call.
      #
      # @return [Proc, nil]
      attr_accessor :on_change

      # @return [Array<Item>] a frozen snapshot of the current items,
      #   in insertion order. Callers cannot mutate the internal
      #   storage through this accessor.
      def items
        @items.dup.freeze
      end

      # @return [Integer]
      def size
        @items.size
      end

      # @return [Boolean]
      def empty?
        @items.empty?
      end

      # Append a new item with status +pending+ and the next id from a
      # monotonic per-list counter. Ids are never reused: after a
      # delete, the freed id stays dead, so a stale id held by the LLM
      # errors loudly instead of silently resolving to a newer task.
      #
      # @param content [String] non-empty content; whitespace is the
      #   caller's responsibility.
      # @return [Item] the newly added item
      # @raise [DuplicateItem] if an item with the same +content+
      #   already exists (a duplicate is almost always an LLM mistake).
      def add(content)
        raise DuplicateItem, content if @items.any? { |i| i.content == content }

        item = Item.new(id: @next_id, content: content, status: 'pending')
        @next_id += 1
        @items << item
        @on_change&.call
        item
      end

      # Update the status of the item whose +id+ matches.
      #
      # @param id [Integer]
      # @param status [String] one of {STATUSES}.
      # @return [Item] the updated item (a fresh frozen +Data+
      #   instance — the old one is replaced in place).
      # @raise [ItemNotFound] if no matching item exists.
      # @raise [ArgumentError] if +status+ is not in {STATUSES}.
      def set_status(id:, status:)
        unless STATUSES.include?(status)
          raise ArgumentError, "invalid status: #{status.inspect} (allowed: #{STATUSES.join(', ')})"
        end

        idx = @items.index { |i| i.id == id }
        raise ItemNotFound, id.to_s if idx.nil?

        @items[idx] = @items[idx].with(status: status)
        @on_change&.call
        @items[idx]
      end

      # Remove the item whose +id+ matches. The id is not reused for
      # later items (see {#add}).
      #
      # @param id [Integer]
      # @return [Item] the removed item.
      # @raise [ItemNotFound] if no matching item exists.
      def delete(id)
        idx = @items.index { |i| i.id == id }
        raise ItemNotFound, id.to_s if idx.nil?

        removed = @items.delete_at(idx)
        @on_change&.call
        removed
      end

      # The canonical rendering returned as the observation by every
      # task tool, so the LLM sees the latest full state — including
      # each item's id — on each call without needing a separate read
      # tool. Format:
      #
      #   <tasks>
      #   - #1 [pending] Add dark mode toggle
      #   - #2 [in_progress] Write unit tests
      #   - #3 [completed] Update README
      #   </tasks>
      #
      # Empty list renders as +<tasks>(empty)</tasks>+ so the LLM gets
      # an unambiguous "yes, the call worked and the list is now empty"
      # signal rather than an ambiguous blank block.
      #
      # @return [String]
      def render
        return '<tasks>(empty)</tasks>' if @items.empty?

        lines = @items.map { |i| "- ##{i.id} [#{i.status}] #{i.content}" }
        "<tasks>\n#{lines.join("\n")}\n</tasks>"
      end
    end
  end
end
