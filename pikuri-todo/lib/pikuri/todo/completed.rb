# frozen_string_literal: true

module Pikuri
  module Todo
    # The +todo_completed+ tool: mark the item whose +content+ exactly
    # matches as +completed+. Same shape and rationale as
    # {InProgress} — the status is baked into the tool name to remove
    # the enum-typo failure mode small models hit on
    # +"completed"+ / +"complete"+ / +"done"+.
    #
    # Returns the rendered current list via {List#render} on success,
    # or +"Error: no such todo: '<content>'"+ when the content does
    # not match.
    class Completed < Pikuri::Tool
      # @return [String]
      DESCRIPTION = <<~DESC
        Mark a todo as `completed` once the work — including any required verification — is actually done.

        Usage:
        - Pass the exact `content` string the todo was created with.
        - Do NOT mark `completed` based on intent; mark it only after the underlying work is verified.
        - If the work is partially done or blocked, leave the todo `in_progress` and add a follow-up via `todo_create`.
        - On `Error: no such todo: ...` the call did nothing — read the returned list in any subsequent tool's output to pick the right name.
        - On success the full current list is returned for you to read back.
      DESC

      # @param list [List]
      # @return [Completed]
      def initialize(list:)
        super(
          name: 'todo_completed',
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_string :content,
                              'Exact content of the existing todo to mark as ' \
                              'completed, e.g. "Add dark mode toggle".'
          },
          execute: lambda { |content:|
            Completed.execute(list: list, content: content)
          }
        )
      end

      # @param list [List]
      # @param content [String]
      # @return [String]
      def self.execute(list:, content:)
        list.set_status(content: content, status: 'completed')
        list.render
      rescue ItemNotFound
        "Error: no such todo: '#{content}'"
      end
    end
  end
end
