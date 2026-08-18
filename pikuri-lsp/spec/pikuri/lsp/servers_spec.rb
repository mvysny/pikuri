# frozen_string_literal: true

describe Pikuri::Lsp::Servers do
  entry = ->(id, files) { Pikuri::Lsp::Registry::StdioEntry.new(id: id, command: [id], files: files) }
  registry = Pikuri::Lsp::Registry.new(entries: [entry.call('ruby', %w[*.rb Rakefile]),
                                                 entry.call('java', %w[*.java])])

  # A stand-in for a started client: {Servers} only ever reads its +entry+ and
  # calls +close+, which is what makes the spawn seam worth having.
  stub_client = Struct.new(:entry, :closed) do
    def close
      self.closed = true
    end
  end

  built = lambda do |the_registry = registry, &block|
    spawned = []
    servers = described_class.new(
      registry: the_registry, root: '/tmp/project',
      spawn: lambda { |spawn_entry|
        spawned << spawn_entry.id
        stub_client.new(spawn_entry, false)
      }
    )
    block.call(servers, spawned)
  end

  it 'spawns every entry at boot, in declaration order' do
    built.call do |servers, spawned|
      servers.start_all

      assert_equal %w[ruby java], spawned
      assert_equal %w[ruby java], servers.all.map { |client| client.entry.id }
    end
  end

  it 'starts nothing twice, so a second call is free' do
    built.call do |servers, spawned|
      servers.start_all
      servers.start_all

      assert_equal %w[ruby java], spawned
    end
  end

  it 'routes on the basename, extension or not' do
    built.call do |servers|
      servers.start_all

      assert_equal 'ruby', servers.client_for('lib/pikuri/agent.rb').entry.id
      assert_equal 'ruby', servers.client_for('/abs/path/Rakefile').entry.id
      assert_equal 'java', servers.client_for('src/main/java/App.java').entry.id
      assert_nil servers.client_for('README.md')
    end
  end

  it 'is empty until started, and empty again after closing' do
    built.call do |servers|
      assert servers.empty?
      servers.start_all
      refute servers.empty?
      clients = servers.all
      servers.close

      assert servers.empty?
      assert clients.all?(&:closed)
    end
  end

  it 'keeps the servers it did start when a later one fails, so the owner can sweep them' do
    started = []
    servers = described_class.new(
      registry: registry, root: '/tmp/project',
      spawn: lambda { |spawn_entry|
        raise Pikuri::Lsp::ClientWrapper::ServerDied, 'no jdtls here' if spawn_entry.id == 'java'

        started << stub_client.new(spawn_entry, false)
        started.last
      }
    )

    assert_raises(Pikuri::Lsp::ClientWrapper::ServerDied) { servers.start_all }
    servers.close

    assert_equal [true], started.map(&:closed)
  end

  it 'answers nothing for an empty registry, so a host that configures none wires no tool' do
    built.call(Pikuri::Lsp::Registry::EMPTY) do |servers, spawned|
      servers.start_all

      assert_empty spawned
      assert servers.empty?
      assert_nil servers.client_for('a.rb')
    end
  end
end
