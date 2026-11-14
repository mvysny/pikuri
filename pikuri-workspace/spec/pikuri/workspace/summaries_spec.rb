# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

# The display line each file tool composes for a chrome — the half of the
# observation the model never sees. Every one is built from a count the tool
# computed, never from a slice of the content, which is what keeps a file's own
# bytes out of a line the user reads as status.
RSpec.describe 'Pikuri::Workspace display summaries' do
  let(:root)       { Pathname.new(Dir.mktmpdir('pikuri-summaries-')).realpath }
  let(:filesystem) { Pikuri::Workspace::Filesystem.new(project_root: root) }
  let(:workspace)  { Pikuri::Workspace::Workspace.new(filesystem: filesystem) }
  let(:confirmer)  { approving_confirmer }

  after { FileUtils.rm_rf(root) }

  def approving_confirmer
    confirmer = Object.new
    confirmer.define_singleton_method(:ask) do |request:, cancellable:|
      Pikuri::Workspace::Confirmer::Approved.new(new_request_detail: request.detail)
    end
    confirmer
  end

  def write_file(rel, content)
    path = root + rel
    FileUtils.mkdir_p(path.dirname)
    File.write(path, content)
    workspace.mark_read(path)
    path
  end

  it 'read: counts the lines it handed over' do
    write_file('app.rb', "zebra\nquagga\nokapi\n")
    tool = Pikuri::Workspace::Read.new(workspace: workspace)

    result = tool.run('path' => 'app.rb')

    assert_equal 'Read 3 lines', result.summary
    refute_includes result.summary, 'zebra', 'the summary must not excerpt the file'
  end

  it 'write: reports the new file\'s size in lines' do
    tool = Pikuri::Workspace::Write.new(workspace: workspace, confirmer: confirmer)

    assert_equal 'Created, 2 lines', tool.run('path' => 'new.rb', 'content' => "x\ny\n").summary
  end

  it 'write: reports both sizes on an overwrite' do
    write_file('old.rb', "a\nb\nc\n")
    tool = Pikuri::Workspace::Write.new(workspace: workspace, confirmer: confirmer)

    result = tool.run('path' => 'old.rb', 'content' => "a\n")

    assert_equal 'Updated, 1 line (was 3)', result.summary
  end

  it 'edit: counts the lines added and removed, exactly, without a differ' do
    write_file('e.rb', "one\ntwo\nthree\n")
    tool = Pikuri::Workspace::Edit.new(workspace: workspace, confirmer: confirmer)

    result = tool.run('path' => 'e.rb', 'old_string' => "two\n", 'new_string' => "TWO\nEXTRA\n")

    assert_equal 'Added 2 lines, removed 1 line', result.summary
  end

  it 'file_list: counts the rows, which the rendered text cannot be counted for' do
    write_file('lib/a.rb', 'a')
    tool = Pikuri::Workspace::FileList.new(workspace: workspace)

    assert_equal 'Listed 1 entry', tool.run({}).summary
    assert_equal 'Listed 2 entries', tool.run('depth' => 2).summary
  end

  it 'file_list: shows the workspace root as "." when the model omits the path' do
    tool = Pikuri::Workspace::FileList.new(workspace: workspace)

    assert_equal '.', tool.describe_call({})
    assert_equal 'lib', tool.describe_call('path' => 'lib')
  end

  it 'glob: counts the matched files' do
    write_file('a.rb', 'x')
    write_file('b.rb', 'x')
    tool = Pikuri::Workspace::Search::Glob.new(workspace: workspace)

    assert_equal 'Found 2 files', tool.run('pattern' => '*.rb').summary
    assert_equal 'Found 0 files', tool.run('pattern' => '*.zzz').summary
  end

  it 'grep: counts the matches and the files holding them' do
    write_file('a.rb', "needle\nhay\n")
    write_file('b.rb', "needle\n")
    tool = Pikuri::Workspace::Search::Grep.new(workspace: workspace)

    result = tool.run('pattern' => 'needle')

    assert_equal 'Found 2 matches in 2 files', result.summary
    refute_includes result.summary, 'needle', 'the summary must not excerpt the matched line'
    assert_equal 'Found 0 matches', tool.run('pattern' => 'nothinghere').summary
  end
end
