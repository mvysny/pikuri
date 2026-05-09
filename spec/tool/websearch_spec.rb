# frozen_string_literal: true

require 'tool'
require 'tool/websearch'

RSpec.describe Tool::Search, '.provider' do
  before { @saved = ENV[Tool::Search::Brave::ENV_KEY] }
  after  { ENV[Tool::Search::Brave::ENV_KEY] = @saved }

  it 'falls back to DuckDuckGo when no Brave key is set' do
    ENV.delete(Tool::Search::Brave::ENV_KEY)
    assert_equal Tool::Search::DuckDuckGo, described_class.provider
  end

  it 'treats a blank Brave key as unset' do
    ENV[Tool::Search::Brave::ENV_KEY] = '   '
    assert_equal Tool::Search::DuckDuckGo, described_class.provider
  end

  it 'picks Brave when its key is set' do
    ENV[Tool::Search::Brave::ENV_KEY] = 'fake-key'
    assert_equal Tool::Search::Brave, described_class.provider
  end
end

RSpec.describe 'Tool::WEB_SEARCH' do
  it 'is advertised to the LLM as `web_search`' do
    assert_equal 'web_search', Tool::WEB_SEARCH.name
  end

  it 'declares a required string `query` parameter' do
    schema = Tool::WEB_SEARCH.parameters.to_h
    assert_equal({ type: 'string', description: 'The search query to perform.' },
                 schema[:properties][:query])
    assert_equal ['query'], schema[:required]
  end
end
