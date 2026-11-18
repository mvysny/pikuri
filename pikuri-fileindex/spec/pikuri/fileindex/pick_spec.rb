# frozen_string_literal: true

RSpec.describe Pikuri::Fileindex do
  # A backend whose probe answers +reason+ and records the folders it probed.
  def backend(label, reason)
    Module.new do
      probes = []
      define_singleton_method(:label) { label }
      define_singleton_method(:probes) { probes }
      define_singleton_method(:unavailable_reason) do |folders:|
        probes << folders
        reason
      end
    end
  end

  def roots = Pikuri::Fileindex::Roots.new(dirs: [Dir.home])

  it 'picks the first ready backend, probing none after it' do
    first = backend('first', 'not installed')
    second = backend('second', nil)
    third = backend('third', nil)

    assert_same second, described_class.pick(roots, backends: [first, second, third])
    assert_equal [[[Dir.home]], [[Dir.home]], []], [first, second, third].map(&:probes)
  end

  it 'names every reason, by label, when no backend is ready' do
    err = assert_raises(described_class::Unavailable) do
      described_class.pick(roots, backends: [backend('localsearch', 'the index holds no files yet.'),
                                             backend('recoll', 'no index in /home/u/.recoll yet.')])
    end
    assert_equal "no file index is ready:\n" \
                 "- localsearch: the index holds no files yet.\n" \
                 '- recoll: no index in /home/u/.recoll yet.', err.message
  end

  it 'prefers localsearch over recoll' do
    assert_equal [Pikuri::Fileindex::LocalSearch, Pikuri::Fileindex::Recoll], described_class::BACKENDS
  end
end
