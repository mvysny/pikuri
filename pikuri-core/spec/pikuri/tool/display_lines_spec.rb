# frozen_string_literal: true

# The three display strings a chrome renders for one tool call — the defaults
# every tool gets for free, and the override seams.
RSpec.describe 'Pikuri::Tool display lines' do
  def tool(name, execute: ->(**) { 'ok' }, &schema)
    Pikuri::Tool.new(name: name, description: 'd',
                     parameters: Pikuri::Tool::Parameters.build(&(schema || proc { |_p| })),
                     execute: execute)
  end

  describe '.display_name_for' do
    it 'CamelCases a snake_case tool name' do
      assert_equal 'WebSearch', Pikuri::Tool.display_name_for('web_search')
      assert_equal 'Read', Pikuri::Tool.display_name_for('read')
      assert_equal 'McpConnect', Pikuri::Tool.display_name_for('mcp_connect')
    end

    it 'renders an MCP server__tool name as Server::Tool' do
      assert_equal 'Openlibrary::SearchBooks', Pikuri::Tool.display_name_for('openlibrary__search_books')
    end

    it 'treats any non-alphanumeric run inside a segment as a word break' do
      assert_equal 'FooBar', Pikuri::Tool.display_name_for('foo-bar')
      assert_equal 'FooBar', Pikuri::Tool.display_name_for('foo..bar')
    end

    it 'keeps the tail of an already-camelCased segment' do
      assert_equal 'SearchBooks', Pikuri::Tool.display_name_for('searchBooks')
    end

    it 'answers "" for a blank name rather than raising' do
      assert_equal '', Pikuri::Tool.display_name_for('')
      assert_equal '', Pikuri::Tool.display_name_for(nil)
    end
  end

  describe '.describe_arguments' do
    it 'renders every supplied argument as k=v' do
      assert_equal 'from=bob after=2026-09',
                   Pikuri::Tool.describe_arguments('from' => 'bob', 'after' => '2026-09')
    end

    it 'answers "" for no arguments or a non-Hash' do
      assert_equal '', Pikuri::Tool.describe_arguments({})
      assert_equal '', Pikuri::Tool.describe_arguments(nil)
    end

    it 'flattens a multi-line value, so one call stays one line' do
      assert_equal 'text=a b', Pikuri::Tool.describe_arguments('text' => "a\n  b")
    end
  end

  describe '.describe_content' do
    it 'counts lines for a multi-line observation and bytes for a single line' do
      assert_equal 'Returned 3 lines', Pikuri::Tool.describe_content("a\nb\nc")
      assert_equal 'Returned 5 bytes', Pikuri::Tool.describe_content('hello')
    end

    it 'passes an "Error: ..." observation through, first line only' do
      assert_equal 'Error: no such file',
                   Pikuri::Tool.describe_content("Error: no such file\nExpected schema:\n  - `path`")
    end

    it "passes ruby_llm's unavailable-tool Hash through" do
      assert_equal 'Model tried to call unavailable tool `nope`.',
                   Pikuri::Tool.describe_content(error: 'Model tried to call unavailable tool `nope`.')
    end

    it 'names the mime and size of a multimodal observation' do
      content = ['note', RubyLLM::Attachment.new(StringIO.new('x' * 2048), filename: 'shot.png')]

      assert_equal 'Returned image/png, 2.0 kB', Pikuri::Tool.describe_content(content)
    end
  end

  describe '#describe_call' do
    it 'shows the first required parameter, which is the primary argument' do
      read = tool('read') { |p|
        p.required_string :path, 'p'
        p.optional_integer :limit, 'l'
      }

      assert_equal 'lib/code/app.rb', read.describe_call('path' => 'lib/code/app.rb', 'limit' => 20)
    end

    it 'accepts Symbol-keyed arguments too' do
      read = tool('read') { |p| p.required_string :path, 'p' }

      assert_equal 'lib/foo.rb', read.describe_call(path: 'lib/foo.rb')
    end

    it 'joins an array argument, rather than dumping it' do
      find = tool('rag_find') { |p| p.required_string_array :terms, 't' }

      assert_equal 'crypto, rotation', find.describe_call('terms' => %w[crypto rotation])
    end

    it 'falls back to k=v when the tool declares no required parameter' do
      search = tool('thunderbird_mail_search') { |p|
        p.optional_string :query, 'q'
        p.optional_string :from, 'f'
      }

      assert_equal 'from=bob', search.describe_call('from' => 'bob')
    end

    it 'falls back to k=v when the model omitted the required parameter' do
      read = tool('read') { |p|
        p.required_string :path, 'p'
        p.optional_integer :limit, 'l'
      }

      assert_equal 'limit=20', read.describe_call('limit' => 20)
    end

    it 'renders a no-parameter tool bare' do
      assert_equal '', tool('enter_plan_mode').describe_call({})
    end
  end

  describe 'the mechanical defaults' do
    it 'derive the display name from the tool name' do
      assert_equal 'WebSearch', tool('web_search').display_name
    end

    it 'derive a summary for a bare String an execute returned' do
      echo = Pikuri::Tool.new(
        name: 'echo', description: 'Echoes.',
        parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :text, 't' },
        execute: ->(text:) { text }
      )

      assert_equal 'Returned 2 bytes', echo.run('text' => 'ok').summary
    end
  end

  describe '#to_ruby_llm_tool' do
    it 'exposes the Pikuri::Tool, so the Agent can reach the display methods' do
      echo = tool('web_search')

      assert_same echo, echo.to_ruby_llm_tool.new.pikuri_tool
    end
  end

  describe Pikuri::Tool::Result do
    it 'reaches the model as its content and the listeners as its summary' do
      result = described_class.new(content: "1. a\n2. b", summary: 'Returned 2 search results')

      assert_equal "1. a\n2. b", result.to_s
      assert_equal 'Returned 2 search results', result.summary
    end

    it 'refuses a non-String content — a Content observation stays bare' do
      assert_raises(ArgumentError) { described_class.new(content: %w[a b], summary: 's') }
    end

    it 'refuses a multi-line summary' do
      assert_raises(ArgumentError) { described_class.new(content: 'c', summary: "two\nlines") }
    end
  end

  describe Pikuri::Tool::Parameters do
    it 'exposes required parameters in declaration order' do
      params = Pikuri::Tool::Parameters.build do |p|
        p.optional_string :limit, 'l'
        p.required_string :path, 'p'
        p.required_string :content, 'c'
      end

      assert_equal %w[path content], params.required
      assert_equal %i[limit path content], params.names
    end
  end
end
