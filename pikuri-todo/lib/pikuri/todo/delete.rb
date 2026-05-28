# frozen_string_literal: true

module Pikuri
  module Todo
    # The +todo_delete+ tool: remove the item whose +content+ exactly
    # matches from the list. Used to drop items that turned out to be
    # unnecessary, were created in error, or have been superseded —
    # rather than leaving them sitting in +pending+ as visual noise.
    #
    # Distinct from {Completed}: +completed+ means the work was
    # actually done; +delete+ means the todo should never have been
    # there. The list itself draws no such distinction once an item
    # is gone, but the LLM picks the right verb because the tool
    # names make the intent clear.
    #
    # Returns the rendered current list via {List#render} on success,
    # or +"Error: no such todo: '<content>'"+ when the content does
    # not match.
    class Delete < Pikuri::Tool
      # @return [String]
      DESCRIPTION = <<~DESC
        Remove a todo from the list. Use this for items that turn out not to be needed, were created in error, or have been superseded.

        Usage:
        - Pass the exact `content` string the todo was created with.
        - Use `todo_completed` (not this) when the work was actually done.
        - On `Error: no such todo: ...` the call did nothing — read the returned list in any subsequent tool's output to pick the right name.
        - On success the full current list is returned for you to read back.
      DESC

      # @param list [List]
      # @return [Delete]
      def initialize(list:)
        super(
          name: 'todo_delete',
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_string :content,
                              'Exact content of the existing todo to remove, ' \
                              'e.g. "Add dark mode toggle".'
          },
          execute: lambda { |content:|
            Delete.execute(list: list, content: content)
          }
        )
      end

      # @param list [List]
      # @param content [String]
      # @return [String]
      def self.execute(list:, content:)
        list.delete(content)
        list.render
      rescue ItemNotFound
        "Error: no such todo: '#{content}'"
      end
    end
  end
end
