# frozen_string_literal: true

module Pikuri
  module Todo
    # Raised by {List#add} when a new item's +content+ already appears
    # in the list. Content doubles as identifier in the todo tools, so
    # duplicates would make +todo_in_progress+ / +todo_completed+ /
    # +todo_delete+ ambiguous. The exception carries the offending
    # content string so the tool layer can surface it verbatim in the
    # +"Error: ..."+ observation.
    class DuplicateItem < StandardError; end

    # Raised by {List#set_status} and {List#delete} when no item with
    # the given +content+ exists. The four todo tools rescue this and
    # report +"Error: no such todo: <content>"+ so the LLM can correct
    # the name on the next turn.
    class ItemNotFound < StandardError; end

    # Allowed values for {Item#status}. Kept deliberately small — three
    # states match the workflow the prompt advertises (pending → in_progress
    # → completed) without inviting a +cancelled+ vs +deleted+ debate.
    # +todo_delete+ removes items outright rather than introducing a
    # fourth status.
    STATUSES = %w[pending in_progress completed].freeze

    # One row in a {List}. +content+ is the LLM-visible string that
    # also acts as identifier across the four todo tools; +status+ is
    # one of {STATUSES}.
    Item = Data.define(:content, :status)

    # An in-memory ordered list of {Item}s, scoped to a single
    # {Pikuri::Agent}. Held inside {Extension} and captured by closure
    # into the +execute+ block of each of the four todo tool classes,
    # so every mutation hits the same instance.
    #
    # == Concurrency
    #
    # The agent loop is single-threaded with respect to tool calls
    # (ruby_llm dispatches them sequentially), so no locking. A future
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
      end

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

      # Append a new item with status +pending+. Content matching is
      # exact (no case- or whitespace-folding) since the tools quote
      # the content back to the LLM as the identifier.
      #
      # @param content [String] non-empty content; whitespace is the
      #   caller's responsibility.
      # @return [Item] the newly added item
      # @raise [DuplicateItem] if an item with the same +content+
      #   already exists.
      def add(content)
        raise DuplicateItem, content if find(content)

        item = Item.new(content: content, status: 'pending')
        @items << item
        item
      end

      # Update the status of the item whose +content+ matches.
      #
      # @param content [String]
      # @param status [String] one of {STATUSES}.
      # @return [Item] the updated item (a fresh frozen +Data+
      #   instance — the old one is replaced in place).
      # @raise [ItemNotFound] if no matching item exists.
      # @raise [ArgumentError] if +status+ is not in {STATUSES}.
      def set_status(content:, status:)
        unless STATUSES.include?(status)
          raise ArgumentError, "invalid status: #{status.inspect} (allowed: #{STATUSES.join(', ')})"
        end

        idx = @items.index { |i| i.content == content }
        raise ItemNotFound, content if idx.nil?

        @items[idx] = Item.new(content: content, status: status)
        @items[idx]
      end

      # Remove the item whose +content+ matches.
      #
      # @param content [String]
      # @return [Item] the removed item.
      # @raise [ItemNotFound] if no matching item exists.
      def delete(content)
        idx = @items.index { |i| i.content == content }
        raise ItemNotFound, content if idx.nil?

        @items.delete_at(idx)
      end

      # The canonical rendering returned as the observation by every
      # todo tool, so the LLM sees the latest full state on each call
      # without needing a separate read tool. Format:
      #
      #   <todos>
      #   - [pending] Add dark mode toggle
      #   - [in_progress] Write unit tests
      #   - [completed] Update README
      #   </todos>
      #
      # Empty list renders as +<todos>(empty)</todos>+ so the LLM gets
      # an unambiguous "yes, the call worked and the list is now empty"
      # signal rather than an ambiguous blank block.
      #
      # @return [String]
      def render
        return '<todos>(empty)</todos>' if @items.empty?

        lines = @items.map { |i| "- [#{i.status}] #{i.content}" }
        "<todos>\n#{lines.join("\n")}\n</todos>"
      end

      private

      def find(content)
        @items.find { |i| i.content == content }
      end
    end
  end
end
