# frozen_string_literal: true

RSpec.describe Pikuri::UrlCache do
  describe 'NULL' do
    it 'always yields and returns the block result' do
      calls = 0
      result = Pikuri::UrlCache::NULL.fetch('https://example.com') do
        calls += 1
        'fresh'
      end
      assert_equal 'fresh', result
      assert_equal 1, calls
    end

    it 'never stores, so a second fetch yields again' do
      calls = 0
      Pikuri::UrlCache::NULL.fetch('k') { calls += 1; 'x' }
      Pikuri::UrlCache::NULL.fetch('k') { calls += 1; 'x' }
      assert_equal 2, calls
    end

    it 'returns a written value but reads nil' do
      assert_equal 'v', Pikuri::UrlCache::NULL.write('k', 'v')
      assert_nil Pikuri::UrlCache::NULL.read('k')
    end
  end
end
