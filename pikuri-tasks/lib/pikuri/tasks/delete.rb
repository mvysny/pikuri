# frozen_string_literal: true

module Pikuri
  module Tasks
    # The +task_delete+ tool: remove the item with the given +id+ from
    # the list. Used to drop items that turned out to be unnecessary,
    # were created in error, or have been superseded — rather than
    # leaving them sitting in +pending+ as visual noise.
    #
    # Distinct from {Completed}: +completed+ means the work was
    # actually done; +delete+ means the task should never have been
    # there. The list itself draws no such distinction once an item
    # is gone, but the LLM picks the right verb because the tool
    # names make the intent clear. A deleted item's id is never
    # reused (see {List#add}), so a stale id errors loudly instead of
    # silently hitting a newer task.
    #
    # Returns the rendered current list via {List#render} on success.
    # On a bad id returns +"Error: no such task id: <id>"+ plus the
    # current list, so the LLM can pick the right id in one turn.
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
