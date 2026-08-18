# frozen_string_literal: true

require 'tmpdir'

describe Pikuri::Lsp::Renderer do
  # A filesystem that denies one path, which is the shape the container wiring
  # produces: a scoped Filesystem answers +denied?+ +false+ for everything.
  denying = Class.new do
    def initialize(filesystem) = @filesystem = filesystem
    def denied?(path) = path.to_s.include?('secret')
    def project_root = @filesystem.project_root
    def resolve_for_read(path) = @filesystem.resolve_for_read(path)
    def private? = @filesystem.private?
  end

  built = lambda do |&block|
    Dir.mktmpdir do |tmp|
      filesystem = denying.new(Pikuri::Workspace::Filesystem.new(project_root: File.realpath(tmp)))
      block.call(described_class.new(sources: Pikuri::Lsp::Sources.new(filesystem: filesystem)),
                 File.realpath(tmp))
    end
  end

  item = lambda do |name, uri, line|
    { 'name' => name, 'kind' => 5, 'uri' => uri,
      'range' => { 'start' => { 'line' => line, 'character' => 0 },
                   'end' => { 'line' => line, 'character' => 5 } } }
  end

  describe '#finish' do
    it 'leaves a short answer alone' do
      built.call { |renderer| assert_equal 'body', renderer.finish('body') }
    end

    it 'appends the notes after the cut, so a long answer cannot lose them' do
      built.call do |renderer|
        renderer.note('a match is outside the workspace.')

        answer = renderer.finish("x#{'y' * described_class::MAX_BYTES}")

        assert_match(/bytes omitted/, answer)
        assert answer.end_with?("Notes:\n- a match is outside the workspace."),
               'the notes are what say a result was dropped; they go last, not first'
      end
    end
  end

  describe '#supertypes' do
    it 'numbers the levels it shows, not the ones it dropped' do
      built.call do |renderer, root|
        levels = [[item.call('Middle', "file://#{root}/secret.rb", 0)],
                  [item.call('Object', "file://#{root}/object.rb", 1)]]

        answer = renderer.supertypes(levels, operation: Pikuri::Lsp::Operation['supertypes'],
                                             symbol: 'Read')

        assert_match(/— 1 level/, answer)
        assert_match(/1\. Object/, answer)
        refute_match(/secret/, answer)
        refute_match(/2\./, answer)
      end
    end
  end
end
