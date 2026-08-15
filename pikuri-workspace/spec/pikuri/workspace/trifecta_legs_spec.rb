# frozen_string_literal: true

require 'tmpdir'

# The trifecta legs the file tools inherit from their workspace, plus the
# two Filesystem flags that decide them.
RSpec.describe 'Workspace trifecta legs' do
  let(:root) { Pathname.new(Dir.mktmpdir('pikuri-legs-root-')).realpath }

  def filesystem(**flags) = Pikuri::Workspace::Filesystem.new(project_root: root, **flags)
  def workspace(**flags) = Pikuri::Workspace::Workspace.new(filesystem: filesystem(**flags))

  after { FileUtils.remove_entry(root) if root.exist? }

  describe 'Filesystem#private? / #trusted?' do
    it 'defaults both off — the framework declares neither for you' do
      fs = filesystem
      refute fs.private?
      refute fs.trusted?
    end

    it 'carries the declared flags' do
      fs = filesystem(private: true, trusted: true)
      assert fs.private?
      assert fs.trusted?
    end
  end

  describe 'Filesystem::AllowAll' do
    it 'accepts private:, where a whole-host workspace is exactly where it is meant' do
      assert Pikuri::Workspace::Filesystem::AllowAll.new(project_root: root, private: true).private?
    end

    it 'refuses trusted: outright — the flag cannot be honest over the whole host' do
      error = assert_raises(ArgumentError) do
        Pikuri::Workspace::Filesystem::AllowAll.new(project_root: root, trusted: true)
      end
      assert_includes error.message, 'not representable'
    end

    it 'reports untrusted even when nothing was declared' do
      refute Pikuri::Workspace::Filesystem::AllowAll.new(project_root: root).trusted?
    end
  end

  describe 'the reading tools' do
    %w[read grep glob].each do |tool_name|
      describe tool_name do
        def build(name, ws)
          case name
          when 'read' then Pikuri::Workspace::Read.new(workspace: ws)
          when 'grep' then Pikuri::Workspace::Search::Grep.new(workspace: ws)
          when 'glob' then Pikuri::Workspace::Search::Glob.new(workspace: ws)
          end
        end

        it 'defaults to hard untrusted — cloned deps and downloads are the norm' do
          legs = build(tool_name, workspace).trifecta_legs
          assert_equal :hard, legs.untrusted
          refute legs.private
          assert_equal :no_egress, legs.egress_payload_review
        end

        it 'inherits the declared private leg' do
          assert build(tool_name, workspace(private: true)).trifecta_legs.private
        end

        it 'drops the untrusted leg on a scoped root vouched for by its owner' do
          assert_equal :none, build(tool_name, workspace(trusted: true)).trifecta_legs.untrusted
        end

        it 'never contributes egress' do
          assert_equal :no_egress, build(tool_name, workspace(private: true)).trifecta_legs.egress_payload_review
        end
      end
    end
  end

  describe 'the writing tools' do
    it 'gives Write no legs — nothing enters the context and a local write is not a sink' do
      tool = Pikuri::Workspace::Write.new(workspace: workspace(private: true),
                                          confirmer: Pikuri::Workspace::Confirmer::AUTO_APPROVE)
      assert_equal Pikuri::Tool::TrifectaLegs::NONE, tool.trifecta_legs
    end

    it 'gives Edit no legs — its bytes arrived through Read, which is where they are tagged' do
      tool = Pikuri::Workspace::Edit.new(workspace: workspace(private: true))
      assert_equal Pikuri::Tool::TrifectaLegs::NONE, tool.trifecta_legs
    end
  end

  describe 'the whole set, walked' do
    it 'reads as two legs — private plus untrusted, with no way out' do
      ws = workspace(private: true)
      tools = [Pikuri::Workspace::Read.new(workspace: ws),
               Pikuri::Workspace::Search::Grep.new(workspace: ws),
               Pikuri::Workspace::Search::Glob.new(workspace: ws),
               Pikuri::Workspace::Edit.new(workspace: ws)]
      node = Pikuri::Trifecta::Node.new(
        label: 'files-only',
        tool_legs: tools.to_h { |t| [t.name, t.trifecta_legs] }
      )

      report = Pikuri::Trifecta.walk(node)
      assert_equal :silent, report.verdict
      assert_equal %i[private untrusted_hard], report.legs.to_tags
    end
  end
end

RSpec.describe 'Confirmer#blocks_on_human?' do
  it 'is true on the base class — a confirmer exists to ask' do
    asking = Class.new(Pikuri::Workspace::Confirmer) do
      def ask(request:) = Pikuri::Workspace::Confirmer::Approved.new(new_request_detail: request.detail)
    end
    assert asking.new.blocks_on_human?
  end

  it 'is false on AutoApprove — nobody is asked, so no gate exists to credit' do
    refute Pikuri::Workspace::Confirmer::AUTO_APPROVE.blocks_on_human?
  end
end
