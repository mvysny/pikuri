# frozen_string_literal: true

module Pikuri
  module Todo
    # The +todo_in_progress+ tool: mark the item whose +content+
    # exactly matches as +in_progress+. The status name is baked into
    # the tool name rather than passed as a parameter — that takes
    # one degree of freedom away from the LLM (no +"in-progress"+ vs
    # +"in_progress"+ vs +"inprogress"+ typos) at the cost of one
    # extra tool class.
    #
    # Returns the rendered current list via {List#render} on success,
    # or +"Error: no such todo: '<content>'"+ when the content does
    # not match — the LLM can read the returned list to find the
    # closest match and re-call.
    class InProgress < Pikuri::Tool
      # @return [String]
      DESCRIPTION = <<~DESC
        Mark a todo as `in_progress` immediately before you start working on it.

        Usage:
        - Pass the exact `content` string the todo was created with — content doubles as identifier; spelling and capitalization must match.
        - Keep exactly one todo `in_progress` at a time. Finish (or revert) the current one before starting another.
        - On `Error: no such todo: ...` the call did nothing — read the returned list in any subsequent tool's output to pick the right name.
        - On success the full current list is returned for you to read back.
      DESC

      # @param list [List]
      # @return [InProgress]
      def initialize(list:)
        super(
          name: 'todo_in_progress',
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_string :content,
                              'Exact content of the existing todo to mark as ' \
                              'in_progress, e.g. "Add dark mode toggle".'
          },
          execute: lambda { |content:|
            InProgress.execute(list: list, content: content)
          }
        )
      end

      # @param list [List]
      # @param content [String]
      # @return [String]
      def self.execute(list:, content:)
        list.set_status(content: content, status: 'in_progress')
        list.render
      rescue ItemNotFound
        "Error: no such todo: '#{content}'"
      end
    end
  end
end
