# frozen_string_literal: true

describe Pikuri::Thunderbird::Launcher do
  Launcher = Pikuri::Thunderbird::Launcher

  # Minimal stand-in for a Subprocess wait result.
  def result(ok:, output: '')
    status = Object.new
    status.define_singleton_method(:success?) { ok }
    Struct.new(:status, :output).new(status, output)
  end

  it 'spawns the resolvable binary with the argument' do
    seen = []
    Launcher.new(thunderbird_bin: '/bin/sh', # any resolvable executable
                 spawn: ->(arg) { seen << arg; result(ok: true) }).launch('mailto:a@x.com')
    assert_equal ['mailto:a@x.com'], seen
  end

  it 'raises Error when the binary cannot be found (before spawning)' do
    spawned = false
    l = Launcher.new(thunderbird_bin: '/nonexistent/thunderbird-xyz',
                     spawn: lambda { |_|
                       spawned = true
                       result(ok: true)
                     })
    err = assert_raises(Launcher::Error) { l.launch('/tmp/x.ics') }
    assert_match(/not found/, err.message)
    refute spawned, 'must not spawn when the binary is missing'
  end

  it 'raises Error when the spawn reports failure' do
    l = Launcher.new(thunderbird_bin: '/bin/sh', spawn: ->(_) { result(ok: false, output: 'boom') })
    err = assert_raises(Launcher::Error) { l.launch('/tmp/x.ics') }
    assert_match(/boom/, err.message)
  end
end
