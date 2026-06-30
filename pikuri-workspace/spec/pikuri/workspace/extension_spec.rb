# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Workspace::Extension do
  let(:root)       { Pathname.new(Dir.mktmpdir('pikuri-ws-ext-')).realpath }
  let(:filesystem) { Pikuri::Workspace::Filesystem.new(project_root: root) }
  let(:confirmer)  { Pikuri::Workspace::Confirmer::AUTO_APPROVE }
  let(:configurator) do
    Pikuri::Agent::Configurator.new(
      transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
      system_prompt_base: 'base',
      id: '',
      streaming: false,
      step_limit: nil,
      cancellable: nil,
      interloper: nil
    )
  end

  after { FileUtils.rm_rf(root) }

  it 'is an Agent::Extension by composition' do
    ext = described_class.new(filesystem: filesystem, confirmer: confirmer)
    assert_kind_of Pikuri::Agent::Extension, ext
  end

  describe '#configure' do
    it 'registers all five file tools' do
      described_class.new(filesystem: filesystem, confirmer: confirmer).configure(configurator)

      names = configurator.tools.map(&:name)
      assert_includes names, 'read'
      assert_includes names, 'grep'
      assert_includes names, 'glob'
      assert_includes names, 'edit'
      assert_includes names, 'write'
    end

    it 'raises if any of its tools was already registered' do
      configurator.add_tool(Pikuri::Workspace::Read.new(workspace: described_class.new(filesystem: filesystem, confirmer: confirmer).workspace))

      err = assert_raises(RuntimeError) do
        described_class.new(filesystem: filesystem, confirmer: confirmer).configure(configurator)
      end
      assert_match(/Read.*cannot be pre-registered/, err.message)
    end
  end

  describe 'shared read record across the registered tools' do
    it 'lets an edit through once the file is read via the registered read tool' do
      File.write(root + 'foo.rb', "alpha\nbeta\n")

      ext = described_class.new(filesystem: filesystem, confirmer: confirmer)
      ext.configure(configurator)
      read = configurator.tools.find { |t| t.name == 'read' }
      edit = configurator.tools.find { |t| t.name == 'edit' }

      # Edit refuses before the shared record knows the file was read.
      refused = edit.run('path' => 'foo.rb', 'old_string' => 'beta', 'new_string' => 'BETA')
      assert refused.start_with?('Error: foo.rb has not been read'), refused

      # Read (same composite) marks it; the edit now clears the gate.
      read.run('path' => 'foo.rb')
      edited = edit.run('path' => 'foo.rb', 'old_string' => 'beta', 'new_string' => 'BETA')
      assert_equal 'Edited foo.rb: replaced 1 occurrence.', edited
    end
  end

  describe '#on_conversation_reset' do
    it 'clears the shared read record so the gate re-arms after a clear' do
      File.write(root + 'foo.rb', "alpha\nbeta\n")

      ext = described_class.new(filesystem: filesystem, confirmer: confirmer)
      ext.configure(configurator)
      read = configurator.tools.find { |t| t.name == 'read' }
      edit = configurator.tools.find { |t| t.name == 'edit' }

      read.run('path' => 'foo.rb') # gate now open for foo.rb

      ext.on_conversation_reset(nil) # the ctx is unused by this hook

      # The read-before-edit gate must refuse again — the cleared
      # conversation has "seen" nothing.
      refused = edit.run('path' => 'foo.rb', 'old_string' => 'beta', 'new_string' => 'BETA')
      assert refused.start_with?('Error: foo.rb has not been read'), refused
    end
  end
end
