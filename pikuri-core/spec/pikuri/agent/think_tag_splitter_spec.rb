# frozen_string_literal: true

RSpec.describe Pikuri::Agent::ThinkTagSplitter do
  # Feeds +chunks+ one by one, then flushes; answers the joined pair.
  def stream(*chunks)
    splitter = described_class.new
    pairs = chunks.map { |c| splitter.feed(c) } << splitter.flush
    [pairs.map(&:first).join, pairs.map(&:last).join]
  end

  describe '.split' do
    it 'separates a leading think block from the answer' do
      assert_equal %w[Hi! hmm], described_class.split("<think>\nhmm\n</think>\n\nHi!")
    end

    it 'passes text without tags through unchanged' do
      assert_equal ['plain answer', ''], described_class.split('plain answer')
    end

    it 'treats an unclosed think block as thinking to the end' do
      assert_equal ['', 'cut off mid-thought'], described_class.split('<think>cut off mid-thought')
    end

    it 'joins several think blocks' do
      assert_equal %w[ab 12], described_class.split('<think>1</think>a<think>2</think>b')
    end
  end

  describe '#feed' do
    it 'holds back a tag cut across chunks until the next one completes it' do
      splitter = described_class.new
      assert_equal ['', ''], splitter.feed('<thi')
      assert_equal %w[Hi hmm], splitter.feed("nk>hmm</think>\nHi")
    end

    it 'splits whatever the chunk boundaries' do
      text = "<think>reasoning</think>\nanswer"
      (1...text.length).each do |cut|
        assert_equal %w[answer reasoning], stream(text[0, cut], text[cut..]), "cut at #{cut}"
      end
      assert_equal %w[answer reasoning], stream(*text.chars)
    end

    it 'releases a held-back near-tag that never became one' do
      assert_equal ['a <thin', ''], stream('a <thin')
      assert_equal ['a <thin b', ''], stream('a <thin', ' b')
    end

    it 'keeps whitespace that does not follow a tag' do
      assert_equal ["\nHi ", ''], stream("\nHi ")
    end
  end
end
