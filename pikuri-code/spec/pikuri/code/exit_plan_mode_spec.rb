# frozen_string_literal: true

RSpec.describe Pikuri::Code::ExitPlanMode do
  let(:read_only) { Pikuri::Workspace::ReadOnly.new }

  # Inline confirmer double: records every request it sees and returns
  # successive elements of +answers+. Calling +confirm?+ with no answer
  # queued raises — surfaces "test silently consumed a confirmation".
  def build_confirmer(*answers)
    queue    = answers.dup
    requests = []
    confirmer = Object.new
    confirmer.define_singleton_method(:confirm?) do |request:|
      requests << request
      raise "unexpected #confirm? call (request: #{request.inspect})" if queue.empty?

      queue.shift
    end
    confirmer.define_singleton_method(:requests) { requests }
    confirmer
  end

  describe '#initialize' do
    it 'builds under the exit_plan_mode name and requires a plan' do
      tool = described_class.new(read_only: read_only, confirmer: build_confirmer)
      assert_equal 'exit_plan_mode', tool.name
      assert_includes tool.parameters.to_openai[:required], 'plan'
    end
  end

  describe '.run while in plan mode' do
    before { read_only.activate! }

    it 'exits plan mode and tells the model to proceed when approved' do
      confirmer = build_confirmer(true)

      result = described_class.run(read_only: read_only, confirmer: confirmer, plan: 'do X')

      refute read_only.active?
      assert_match(/no longer in plan mode/i, result)
    end

    it 'shows the plan to the user as the request detail' do
      confirmer = build_confirmer(true)

      described_class.run(read_only: read_only, confirmer: confirmer, plan: "## Plan\n1. step")

      assert_equal "## Plan\n1. step", confirmer.requests.first.detail
    end

    it 'stays in plan mode and steers a refine when declined' do
      confirmer = build_confirmer(false)

      result = described_class.run(read_only: read_only, confirmer: confirmer, plan: 'do X')

      assert read_only.active?
      assert_match(/still in plan mode/i, result)
    end
  end

  describe '.run when not in plan mode' do
    it 'returns a nothing-to-exit observation without consulting the confirmer' do
      confirmer = build_confirmer # raises if consulted

      result = described_class.run(read_only: read_only, confirmer: confirmer, plan: 'do X')

      assert_match(/nothing to exit/i, result)
      assert_empty confirmer.requests
    end
  end
end
