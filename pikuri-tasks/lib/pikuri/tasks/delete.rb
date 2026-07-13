# frozen_string_literal: true

module Pikuri
  module Tasks
    # The +task_delete+ tool: remove the item with the given +id+.
    # Distinct from {Completed} in intent — +completed+ means the work was
    # done, +delete+ means the task shouldn't have been there — a
    # distinction the tool names carry, not the list. A deleted id is never
    # reused ({List#add}). Returns {List#render}; a bad id returns
    # +"Error: no such task id"+ plus the current list.
    class Delete < Pikuri::Tool
      # @return [String]
      DESCRIPTION = <<~DESC
        Remove a task from the list. Use this for items that turn out not to be needed, were created in error, or have been superseded.

        Usage:
        - Pass the task's numeric `id` as shown in the rendered list (`- #3 [pending] ...` → id 3).
        - Use `task_completed` (not this) when the work was actually done.
        - On `Error: no such task id: ...` the call did nothing — the error includes the current list; pick the right id from it.
        - On success the full current list is returned for you to read back.
      DESC

      # @param list [List]
      # @return [Delete]
      def initialize(list:)
        super(
          name: 'task_delete',
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_integer :id,
                               'Numeric id of the existing task to remove, ' \
                               'as shown in the rendered list, e.g. 3.'
          },
          execute: lambda { |id:|
            Delete.execute(list: list, id: id)
          }
        )
      end

      # @param list [List]
      # @param id [Integer]
      # @return [String]
      def self.execute(list:, id:)
        list.delete(id)
        list.render
      rescue ItemNotFound
        "Error: no such task id: #{id}. Current list:\n#{list.render}"
      end
    end
  end
end
