# frozen_string_literal: true

module Pikuri
  module Tasks
    # Raised by {List#add} when a new item's +content+ already appears in
    # the list — rejected because a duplicate is almost always an LLM
    # mistake (re-sending an already-captured plan). Carries the offending
    # content for the +"Error: ..."+ observation.
    class DuplicateItem < StandardError; end

    # Raised by {List#set_status} and {List#delete} when no item with the
    # given +id+ exists; the mutation tools rescue it into an +"Error: no
    # such task id"+ observation.
    class ItemNotFound < StandardError; end

    # Allowed values for {Item#status}. Deliberately three — the workflow
    # the prompt advertises (pending → in_progress → completed) — with
    # +task_delete+ removing items outright rather than adding a fourth
    # +cancelled+/+deleted+ status.
    STATUSES = %w[pending in_progress completed].freeze

    # One row in a {List}. +id+ is the numeric identifier the mutation
    # tools address the item by (assigned by {List#add}, never reused);
    # +content+ is the LLM-visible task text; +status+ is one of {STATUSES}.
    Item = Data.define(:id, :content, :status)

    # An in-memory ordered list of {Item}s, scoped to a single
    # {Pikuri::Agent}, shared by closure into all four task tools so every
    # mutation hits the same instance.
    #
    # Agent-thread-confined: the loop dispatches tool calls sequentially,
    # so there's no locking. Other threads (a UI rendering the list) must
    # not touch a +List+ directly — they consume the {ListChanged} events
    # {Extension#bind} wires onto the listener stream, whose +items+
    # payload is an immutable snapshot safe to hand across threads.
    #
    # Not persisted: dropped when the +Agent+ is collected, matching the
    # gem's "in-memory only" scope.
    class List
      # @return [List]
      def initialize
        @items = []
        @next_id = 1
        @on_change = nil
      end

      # Optional zero-argument hook invoked synchronously after every
      # *successful* mutation (a raise means nothing changed, so no
      # notify). Set by {Extension#bind} to emit a {ListChanged}; +nil+
      # (default) disables notification.
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
      # @raise [DuplicateItem] if an item with the same +content+ exists.
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

      # Drop every item and rewind the id counter to 1, then fire
      # {#on_change} (always, even when already empty, so a UI listener
      # sees the cleared state). Rewinding +@next_id+ is safe here — unlike
      # after {#delete}, a clear wipes the model's context too, so no stale
      # id survives to collide with a reused one.
      #
      # @return [void]
      def clear
        @items = []
        @next_id = 1
        @on_change&.call
        nil
      end

      # The canonical rendering every task tool returns as its
      # observation, so the LLM sees the full state (ids included) each
      # call without a separate read tool:
      #
      #   <tasks>
      #   - #1 [pending] Add dark mode toggle
      #   - #2 [in_progress] Write unit tests
      #   - #3 [completed] Update README
      #   </tasks>
      #
      # Empty renders as +<tasks>(empty)</tasks>+ — an unambiguous "the
      # call worked, list is now empty" rather than a blank block.
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
