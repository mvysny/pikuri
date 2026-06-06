# frozen_string_literal: true

module Pikuri
  module Tasks
    # The +task_in_progress+ tool: mark the item with the given +id+
    # as +in_progress+. The status name is baked into the tool name
    # rather than passed as a parameter — that takes one degree of
    # freedom away from the LLM (no +"in-progress"+ vs +"in_progress"+
    # vs +"inprogress"+ typos) at the cost of one extra tool class.
    #
    # Items are addressed by the numeric +#id+ shown in every rendered
    # list (an earlier design used the content string as identifier;
    # one near-miss in reproducing the exact bytes — a stray quote, a
    # trailing comma — and the LLM is locked out of its own list. An
    # id is two digits it just read back; nothing to mis-transcribe.)
    #
    # Returns the rendered current list via {List#render} on success.
    # On a bad id returns +"Error: no such task id: <id>"+ plus the
    # current list, so the LLM can pick the right id in one turn.
    class InProgress < Pikuri::Tool
      # @return [String]
      DESCRIPTION = <<~DESC
        Mark a task as `in_progress` immediately before you start working on it.

        Usage:
        - Pass the task's numeric `id` as shown in the rendered list (`- #3 [pending] ...` → id 3).
        - Keep exactly one task `in_progress` at a time. Finish (or revert) the current one before starting another.
        - On `Error: no such task id: ...` the call did nothing — the error includes the current list; pick the right id from it.
        - On success the full current list is returned for you to read back.
      DESC

      # @param list [List]
      # @return [InProgress]
      def initialize(list:)
        super(
          name: 'task_in_progress',
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_integer :id,
                               'Numeric id of the existing task to mark as ' \
                               'in_progress, as shown in the rendered list, e.g. 3.'
          },
          execute: lambda { |id:|
            InProgress.execute(list: list, id: id)
          }
        )
      end

      # @param list [List]
      # @param id [Integer]
      # @return [String]
      def self.execute(list:, id:)
        list.set_status(id: id, status: 'in_progress')
        list.render
      rescue ItemNotFound
        "Error: no such task id: #{id}. Current list:\n#{list.render}"
      end
    end
  end
end
