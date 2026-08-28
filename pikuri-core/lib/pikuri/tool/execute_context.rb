# frozen_string_literal: true

module Pikuri
  class Tool
    # The per-call environment handed to an +execute+ Proc alongside its
    # validated arguments — everything a tool might need to know about *this
    # invocation* that the LLM did not supply.
    #
    #   Tool.new(
    #     name: 'web_search', description: DESCRIPTION, parameters: params,
    #     wants_context: true,
    #     execute: ->(query:, context:) { cascade.search(query, cancellable: context.cancellable) }
    #   )
    #
    # A tool opts in with +wants_context: true+ and takes a +context:+ keyword;
    # both halves are required, so getting one without the other is an
    # +ArgumentError+ on the first call rather than a silent +nil+. Most tools
    # want neither.
    #
    # == Why the arguments are *not* in here
    #
    # The obvious shape is +context.args[:query]+, with one object carrying
    # everything. It loses to a plain fact about {Parameters#validate}: it
    # returns only the keys the model actually sent and applies no defaults, so
    # half the bundled tools declare theirs in the +execute+ signature
    # (+max_results: 10+). Fold the arguments in here and every one of those
    # defaults has to be re-expressed. Arguments therefore stay kwargs, and this
    # object carries only what has no other home.
    #
    # Growing it is the point: a new field is added here and read by the tools
    # that care, with no signature change anywhere else.
    ExecuteContext = Data.define(:cancellable) do
      # The context a {Tool#run} with no caller-supplied one uses: cancellation
      # that never trips. Frozen like every +Data+, so it is safe to share.
      #
      # @return [ExecuteContext]
      def self.default
        @default ||= new(cancellable: Pikuri::Agent::Control::Cancellable::NEVER)
      end
    end
  end
end
