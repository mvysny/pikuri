# frozen_string_literal: true

module Pikuri
  module Tasks
    # The +task_completed+ tool: mark the item with the given +id+ as
    # +completed+. Same shape as {InProgress} (status in the tool name,
    # item addressed by numeric +#id+). Returns {List#render}; a bad id
    # returns +"Error: no such task id"+ plus the current list.
    #
    # Sharing: +P_one_agent+ — closes over one agent's {List}; see its
    # +== Sharing+.
    class Completed < Pikuri::Tool
      # @return [String]
      DESCRIPTION = <<~DESC
        Mark a task as `completed` once the work — including any required verification — is actually done.

        Usage:
        - Pass the task's numeric `id` as shown in the rendered list (`- #3 [in_progress] ...` → id 3).
        - Do NOT mark `completed` based on intent; mark it only after the underlying work is verified.
        - If the work is partially done or blocked, leave the task `in_progress` and add a follow-up via `task_create`.
        - On `Error: no such task id: ...` the call did nothing — the error includes the current list; pick the right id from it.
        - On success the full current list is returned for you to read back.
      DESC

      # @param list [List]
      # @return [Completed]
      def initialize(list:)
        super(
          name: 'task_completed',
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_integer :id,
                               'Numeric id of the existing task to mark as ' \
                               'completed, as shown in the rendered list, e.g. 3.'
          },
          execute: lambda { |id:|
            Completed.execute(list: list, id: id)
          },
          # No legs; see {Create}.
          trifecta_legs: Pikuri::Tool::TrifectaLegs::NONE
        )
      end

      # @param list [List]
      # @param id [Integer]
      # @return [String]
      def self.execute(list:, id:)
        list.set_status(id: id, status: 'completed')
        list.render
      rescue ItemNotFound
        "Error: no such task id: #{id}. Current list:\n#{list.render}"
      end
    end
  end
end
