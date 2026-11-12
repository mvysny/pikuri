# frozen_string_literal: true

RSpec.describe Pikuri::Web::ReadCached do
  let(:store) { Pikuri::Web::Search::PageStore.new }

  def put(text, indexed_at: nil)
    store.store(url: 'https://example.com/a', title: 'Page A', text: text, indexed_at: indexed_at)
  end

  it 'returns the URL, title, index time and text of a stored page' do
    handle = put('body text', indexed_at: Time.utc(2026, 11, 10, 5, 22, 14))
    result = described_class.read(handle, store: store)
    assert_equal "URL: https://example.com/a\nTitle: Page A\nIndexed: 2026-11-10T05:22:14Z\n\nbody text",
                 result.content
    assert_equal 'Read 9 B', result.summary
  end

  it 'leaves out the Indexed line when the engine gave no time' do
    handle = put('body text')
    assert_equal "URL: https://example.com/a\nTitle: Page A\n\nbody text", described_class.read(handle, store: store).content
  end

  it 'cuts the text at max_chars with web_scrape\'s marker' do
    handle = put('x' * 50)
    content = described_class.read(handle, max_chars: 10, store: store).content
    assert_includes content, "#{'x' * 10}\n\n... [truncated at 10 of 50 chars;"
  end

  it 'answers an unknown handle with an error telling the model to search again' do
    result = described_class.read('deadbeef', store: store)
    assert result.error?
    assert_includes result.content, 'No stored page for handle "deadbeef"'
    assert_includes result.content, 'Run web_search again'
  end

  describe 'READ_CACHED' do
    let(:tool) { Pikuri::Web::READ_CACHED }

    it 'holds no egress leg: it makes no request' do
      legs = tool.trifecta_legs
      refute legs.egress?
      refute legs.private
      assert_equal :hard, legs.untrusted
    end

    it 'reads from the process-wide store' do
      handle = Pikuri::Web::Search::PageStore.default.store(url: 'https://example.com/z', title: 'Z',
                                                             text: 'zed', indexed_at: nil)
      assert_includes tool.run(handle: handle).content, "\n\nzed"
    end
  end
end
