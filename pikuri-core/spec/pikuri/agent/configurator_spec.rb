# frozen_string_literal: true

RSpec.describe Pikuri::Agent::Configurator do
  let(:transport) { Pikuri::Agent::ChatTransport.new(model: 'm') }

  def new_configurator(**overrides)
    Pikuri::Agent::Configurator.new(
      transport: transport,
      system_prompt_base: 'base',
      id: '',
      streaming: false,
      cancellable: nil,
      interloper: nil,
      **overrides
    )
  end

  describe '#initialize' do
    it 'exposes the constructor inputs verbatim via attr_readers' do
      cancellable = Pikuri::Agent::Control::Cancellable.new
      c = new_configurator(id: 'researcher 0', streaming: true,
                           cancellable: cancellable)

      assert_equal transport, c.transport
      assert_equal 'base', c.system_prompt_base
      assert_equal 'researcher 0', c.id
      assert_equal true, c.streaming
      assert_same cancellable, c.cancellable
    end

    it 'starts with empty collections' do
      c = new_configurator
      assert_equal [], c.tools
      assert_equal [], c.sub_agent_tools
      assert_equal [], c.listeners
      assert_equal [], c.on_close_handlers
      assert_equal [], c.extensions
    end
  end

  describe '#add_tool' do
    it 'appends in declaration order' do
      c = new_configurator
      c.add_tool(:t1)
      c.add_tool(:t2)
      assert_equal %i[t1 t2], c.tools
    end

    it 'does not bleed into sub_agent_tools' do
      c = new_configurator
      c.add_tool(:t1)
      assert_equal [], c.sub_agent_tools
    end
  end

  describe '#add_sub_agent_tool' do
    it 'appends to the sub-agent pool in declaration order' do
      c = new_configurator
      c.add_sub_agent_tool(:s1)
      c.add_sub_agent_tool(:s2)
      assert_equal %i[s1 s2], c.sub_agent_tools
    end

    it 'does not bleed into the parent tool list' do
      c = new_configurator
      c.add_sub_agent_tool(:s1)
      assert_equal [], c.tools
    end
  end

  describe '#add_listener' do
    it 'appends in declaration order' do
      c = new_configurator
      c.add_listener(:l1)
      c.add_listener(:l2)
      assert_equal %i[l1 l2], c.listeners
    end
  end

  describe '#on_close' do
    it 'collects handler blocks in declaration order' do
      c = new_configurator
      a = -> { :a }
      b = -> { :b }
      c.on_close(&a)
      c.on_close(&b)
      assert_equal [a, b], c.on_close_handlers
    end

    it 'raises ArgumentError without a block' do
      c = new_configurator
      assert_raises(ArgumentError) { c.on_close }
    end
  end

  describe '#add_extension' do
    # An extension that just records what it gets, then accepts the
    # default no-op bind from Pikuri::Agent::Extension. Mixing the
    # module in is the canonical way to write an extension; the
    # Configurator's contract calls #configure unconditionally so
    # the module's defaults stop NoMethodError fires for omitted
    # methods.
    let(:extension_class) do
      Class.new do
        include Pikuri::Agent::Extension

        attr_reader :configured_with

        def configure(c)
          @configured_with = c
        end
      end
    end

    it 'calls extension.configure(self) immediately and retains the instance' do
      c = new_configurator
      ext = extension_class.new

      c.add_extension(ext)

      assert_same c, ext.configured_with
      assert_equal [ext], c.extensions
    end

    it 'raises if the extension has no #configure (the module provides a default)' do
      c = new_configurator
      ext = Object.new # no include, no methods

      assert_raises(NoMethodError) { c.add_extension(ext) }
    end

    it 'lets a later extension read what previous ones added' do
      # Source order == execution order — useful when an extension
      # wants to behave differently based on what's already wired.
      c = new_configurator
      ext1 = Class.new do
        include Pikuri::Agent::Extension
        def configure(cfg) = cfg.add_tool(:t1)
      end.new
      observed = nil
      ext2 = Class.new do
        include Pikuri::Agent::Extension
        define_method(:configure) { |cfg| observed = cfg.tools.dup }
      end.new

      c.add_extension(ext1)
      c.add_extension(ext2)

      assert_equal [:t1], observed
    end

    it 'refuses an instance already added to another agent, before configuring it again' do
      ext = extension_class.new
      first = new_configurator
      first.add_extension(ext)
      second = new_configurator

      err = assert_raises(ArgumentError) { second.add_extension(ext) }

      assert_includes err.message, 'already added to an agent'
      assert_same first, ext.configured_with
      assert_equal [], second.extensions
    end

    it 'refuses the same instance added twice to one agent' do
      c = new_configurator
      ext = extension_class.new
      c.add_extension(ext)

      assert_raises(ArgumentError) { c.add_extension(ext) }
      assert_equal [ext], c.extensions
    end

    it 'tells equal extensions apart by identity' do
      value_class = Data.define(:name) { include Pikuri::Agent::Extension }
      c = new_configurator

      c.add_extension(value_class.new(name: 'x'))
      c.add_extension(value_class.new(name: 'x'))

      assert_equal 2, c.extensions.size
    end
  end

  describe Pikuri::Agent::Extension do
    it 'provides no-op default implementations of #configure and #bind' do
      # The mixin's whole reason for being: an extension that only
      # needs one hook can omit the other and inherit a safe no-op.
      ext = Class.new { include Pikuri::Agent::Extension }.new

      assert_respond_to ext, :configure
      assert_respond_to ext, :bind

      # Default impls accept the expected arguments and return nil
      # without side effects.
      assert_nil ext.configure(:any_configurator)
      assert_nil ext.bind(:any_agent)
    end
  end
end
