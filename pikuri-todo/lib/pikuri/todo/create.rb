# frozen_string_literal: true

module Pikuri
  module Todo
    # The +todo_create+ tool: mass-create pending items in a single
    # call from a newline-separated +items+ string. Why
    # newline-separated rather than a JSON array: it stays within
    # pikuri's scalar-only +Tool::Parameters+ DSL (no array support
    # to extend), and a smaller model never has to balance brackets
    # or escape quotes — fewer formatting failure modes on the burst
    # of items that opens most multi-step tasks.
    #
    # Each line is right- and left-stripped; blank lines are skipped.
    # If any input is a duplicate (within the batch, or already in
    # the list), the whole call aborts with an +"Error: ..."+ string
    # and nothing is added — the LLM resends a corrected batch on the
    # next turn. Atomic semantics keep the list in a coherent state
    # the LLM doesn't have to reconcile.
    #
    # On success returns the rendered current list via {List#render},
    # so the LLM always sees fresh state without a separate read tool.
    class Create < Pikuri::Tool
      # @return [String] static description shown to the LLM,
      #   opencode-shape (summary + +Usage:+ bullets).
      DESCRIPTION = <<~DESC
        Create one or more new todo items in a single call. All items start as `pending`.

        Usage:
        - Use at the start of a multi-step task to capture the plan.
        - `items` is a single newline-separated string — one todo per line. Blank lines are ignored.
        - Duplicate content (within the batch or already on the list) aborts the whole call with `Error: ...` and adds nothing — resend a corrected batch.
        - Empty input is rejected the same way.
        - On success the full current list is returned for you to read back.
      DESC

      # @param list [List] the shared per-Agent list, captured by
      #   closure so every tool in the {Extension}'s set mutates the
      #   same instance.
      # @return [Create]
      def initialize(list:)
        super(
          name: 'todo_create',
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_string :items,
                              'Newline-separated list of todo contents, e.g. ' \
                              '"Add dark mode toggle\nWrite unit tests\nUpdate README". ' \
                              'Blank lines are ignored.'
          },
          execute: lambda { |items:|
            Create.execute(list: list, items: items)
          }
        )
      end

      # Validate and apply the batch. Public so specs can drive it
      # without constructing a tool instance.
      #
      # @param list [List]
      # @param items [String] raw +items+ argument from the LLM.
      # @return [String] either {List#render} on success or an
      #   +"Error: ..."+ string the LLM can react to.
      def self.execute(list:, items:)
        cleaned = items.lines.map(&:strip).reject(&:empty?)
        return 'Error: todo_create requires at least one non-blank item' if cleaned.empty?

        seen_in_batch = {}
        cleaned.each do |c|
          return "Error: duplicate item in batch: '#{c}'" if seen_in_batch[c]

          seen_in_batch[c] = true
        end

        existing = list.items.map(&:content)
        clash = cleaned.find { |c| existing.include?(c) }
        return "Error: todo already exists: '#{clash}'" if clash

        cleaned.each { |c| list.add(c) }
        list.render
      end
    end
  end
end
