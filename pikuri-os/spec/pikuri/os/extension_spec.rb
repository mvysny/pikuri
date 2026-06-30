# frozen_string_literal: true

require 'pathname'

RSpec.describe Pikuri::Os::Extension do
  let(:filesystem) { Pikuri::Workspace::Filesystem::AllowAll.new(project_root: Dir.pwd) }
  let(:human) { Pikuri::Workspace::Confirmer::AutoApprove.new }

  # Deterministic stand-ins so the spec doesn't depend on inxi / a real
  # MACHINE.md / localsearch for the prompt assertions.
  let(:system_info) do
    Object.new.tap { |o| o.define_singleton_method(:prompt_section) { "# This machine\n\n- OS: TestOS" } }
  end
  let(:memory) do
    Object.new.tap do |o|
      o.define_singleton_method(:prompt_section) { nil } # nothing recorded → affordance path
      o.define_singleton_method(:path) { Pathname.new('/cfg/pikuri/MACHINE.md') }
    end
  end

  def build_configurator
    Pikuri::Agent::Configurator.new(
      transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
      system_prompt_base: 'base', id: '', streaming: false,
      step_limit: nil, cancellable: nil, interloper: nil
    )
  end

  def with_singleton(obj, name)
    original = obj.method(name)
    yield original
  ensure
    obj.define_singleton_method(name, original)
  end

  # Pretend localsearch is present without spawning it (check_binaries!
  # would otherwise shell out and fail in CI).
  def stub_localsearch_available(present)
    Pikuri::Os::LocalSearch.define_singleton_method(:available?) { present }
    Pikuri::Os::LocalSearch.define_singleton_method(:check_binaries!) { nil }
  end

  def configure!(c, read_only: nil)
    ext = described_class.new(
      filesystem: filesystem, confirmer: human, read_only: read_only,
      memory: memory, system_info: system_info
    )
    ext.configure(c)
    ext
  end

  it 'is an Agent::Extension by composition' do
    assert_kind_of Pikuri::Agent::Extension,
                   described_class.new(filesystem: filesystem, confirmer: human)
  end

  describe '#configure when localsearch is available' do
    it 'wires the file tools, bash, and both file-index tools' do
      with_singleton(Pikuri::Os::LocalSearch, :available?) do
        with_singleton(Pikuri::Os::LocalSearch, :check_binaries!) do
          stub_localsearch_available(true)
          c = build_configurator
          configure!(c)

          names = c.tools.map(&:name)
          %w[read write edit grep glob bash fileindex_search fileindex_read].each do |t|
            assert_includes names, t
          end
        end
      end
    end

    it 'contributes the machine facts and the memory affordance via system_prompt_snippets' do
      with_singleton(Pikuri::Os::LocalSearch, :available?) do
        with_singleton(Pikuri::Os::LocalSearch, :check_binaries!) do
          stub_localsearch_available(true)
          c = build_configurator
          ext = configure!(c)

          additions = ext.system_prompt_snippets.join("\n")
          assert_includes additions, '# This machine'
          assert_includes additions, '- OS: TestOS'
          # memory.prompt_section was nil → affordance naming the path
          assert_includes additions, '/cfg/pikuri/MACHINE.md'
        end
      end
    end

    it 'gives Bash a ReadOnlyAutoConfirmer wrapping the human confirmer, with allow_git on (Write keeps the human one)' do
      with_singleton(Pikuri::Os::LocalSearch, :available?) do
        with_singleton(Pikuri::Os::LocalSearch, :check_binaries!) do
          with_singleton(Pikuri::Code::Bash::ReadOnlyAutoConfirmer, :new) do |orig|
            stub_localsearch_available(true)
            captured = nil
            captured_allow_git = nil
            Pikuri::Code::Bash::ReadOnlyAutoConfirmer.define_singleton_method(:new) do |inner, allow_git: false|
              captured = inner
              captured_allow_git = allow_git
              orig.call(inner, allow_git: allow_git)
            end

            configure!(build_configurator)
            assert_same human, captured, 'Bash should be gated by a ReadOnlyAutoConfirmer over the human confirmer'
            assert captured_allow_git, 'pikuri-os enables allow_git: true (read-only git auto-approves, backed by Bash env hardening)'
          end
        end
      end
    end
  end

  describe 'read-only / plan-mode propagation through the composite' do
    # Os::Extension composes Workspace::Extension + Code::Extension, both
    # of which take read_only:. A flag handed to Os::Extension must
    # therefore light up the enter/exit tools transitively — this guards
    # against a refactor silently dropping that propagation.
    it 'wires the enter/exit tools when a read-only flag is present' do
      with_singleton(Pikuri::Os::LocalSearch, :available?) do
        with_singleton(Pikuri::Os::LocalSearch, :check_binaries!) do
          stub_localsearch_available(true)
          c = build_configurator
          configure!(c, read_only: Pikuri::Workspace::ReadOnly.new)

          names = c.tools.map(&:name)
          assert_includes names, 'enter_plan_mode'
          assert_includes names, 'exit_plan_mode'
        end
      end
    end

    it 'omits the plan-mode tools when no flag is wired' do
      with_singleton(Pikuri::Os::LocalSearch, :available?) do
        with_singleton(Pikuri::Os::LocalSearch, :check_binaries!) do
          stub_localsearch_available(true)
          c = build_configurator
          configure!(c) # read_only: nil

          names = c.tools.map(&:name)
          refute_includes names, 'enter_plan_mode'
          refute_includes names, 'exit_plan_mode'
        end
      end
    end
  end

  describe '#configure when localsearch is absent' do
    it 'omits the file-index tools but still wires file tools + bash' do
      with_singleton(Pikuri::Os::LocalSearch, :available?) do
        Pikuri::Os::LocalSearch.define_singleton_method(:available?) { false }
        c = build_configurator
        configure!(c)

        names = c.tools.map(&:name)
        assert_includes names, 'bash'
        assert_includes names, 'read'
        refute_includes names, 'fileindex_search'
        refute_includes names, 'fileindex_read'
      end
    end
  end
end
