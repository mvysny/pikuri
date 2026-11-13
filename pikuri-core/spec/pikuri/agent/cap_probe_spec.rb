# frozen_string_literal: true

require 'pikuri/testing' # opt-in scaffolding, not loaded by pikuri-core boot

# The first-turn /props probe through a REAL Agent + ruby_llm loop: when it runs,
# which model it asks about, and when a stated transport spares it.
RSpec.describe 'Agent /props probe' do
  def transport(**kwargs)
    Pikuri::Testing.fake_transport(**kwargs) { |llm| llm.reply('done') }
  end

  # Stand in for a llama.cpp answering /props; the real probe's own HTTP is
  # exercised in context_window_detector_spec. Counts its calls, because
  # half of what this section asserts is a probe *not* paid.
  before do
    probes = @probes = []
    @original_detect = Pikuri::Agent::ContextWindowDetector.method(:detect)
    props = Pikuri::Agent::ContextWindowDetector::Props.new(n_ctx: 16_384, total_slots: 4)
    Pikuri::Agent::ContextWindowDetector.define_singleton_method(:detect) do |probed, **_|
      probes << probed.model
      props
    end
  end

  after do
    Pikuri::Agent::ContextWindowDetector.define_singleton_method(:detect, @original_detect)
  end

  def served(transport)
    Pikuri::Agent.new(transport: transport, system_prompt: 's').tap { |a| a.run_loop(user_message: 'hi') }
  end

  it 'probes nothing at construction' do
    built = Pikuri::Agent.new(transport: transport(context_window: nil), system_prompt: 's')

    assert_equal [], @probes
    assert_nil built.context_window_cap
  ensure
    built&.close
  end

  # The reason the probe waits: against a router, /props?model=<id> loads that
  # model, and a host switching before its first turn would load one for nothing.
  it 'probes only the model switched to before the first turn' do
    built = Pikuri::Agent.new(transport: transport(model: 'boot-model', context_window: nil), system_prompt: 's')
    built.run_loop(user_message: 'hi', transport: transport(model: 'chosen-model', context_window: nil))

    assert_equal ['chosen-model'], @probes
    assert_equal 16_384, built.context_window_cap
  ensure
    built&.close
  end

  # n_ctx is a live reading (restart llama-server with a different -c and the
  # next agent sees it), so an agent that needs one always probes.
  it 'probes per agent when no cap is stated' do
    built = Array.new(3) { served(transport(context_window: nil)) }

    assert_equal [16_384] * 3, built.map(&:context_window_cap)
    assert_equal 3, @probes.size
  ensure
    built&.each(&:close)
  end

  # Modalities are a per-model reading like n_ctx: a stated cap alone is not
  # enough to skip the probe while they are unknown.
  it 'probes a capped agent whose modalities are unknown' do
    built = served(transport(context_window: 8192, modalities: nil))

    assert_equal 1, @probes.size
    assert_equal 8192, built.context_window_cap
    assert_equal({}, built.modalities)
  ensure
    built&.close
  end

  # The shape SubAgentTool spawns with: the parent's resolved cap and
  # modalities ride the transport.
  it 'costs a sub-agent spawn no probe of its own' do
    parent = served(transport(context_window: nil, modalities: nil))
    child = served(transport(context_window: parent.context_window_cap, modalities: parent.modalities))

    assert_equal 16_384, child.context_window_cap
    assert_equal 1, @probes.size
  ensure
    parent&.close
    child&.close
  end
end
