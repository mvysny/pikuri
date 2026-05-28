# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::VectorDb::Tokenizer::CharHeuristic do
  describe 'with the default 4 chars/token ratio' do
    let(:tokenizer) { Pikuri::VectorDb::Tokenizer::CharHeuristic.new }

    it 'counts the empty string as 0' do
      assert_equal 0, tokenizer.count('')
    end

    it 'rounds up sub-token strings to 1' do
      assert_equal 1, tokenizer.count('a')
      assert_equal 1, tokenizer.count('hi')
      assert_equal 1, tokenizer.count('abc')
    end

    it 'counts exact multiples of 4 as length / 4' do
      assert_equal 1, tokenizer.count('abcd')
      assert_equal 4, tokenizer.count('abcdefghijklmnop')
    end

    it 'rounds non-multiples up' do
      # 17 chars / 4 = 4.25 → 5
      assert_equal 5, tokenizer.count('abcdefghijklmnopq')
    end
  end

  describe 'with a custom chars_per_token' do
    it 'honors a denser ratio (e.g., Mandarin ≈ 2 chars/token)' do
      tokenizer = Pikuri::VectorDb::Tokenizer::CharHeuristic.new(chars_per_token: 2.0)
      assert_equal 8, tokenizer.count('abcdefghijklmnop') # 16 chars / 2 = 8
    end

    it 'accepts fractional ratios' do
      # Japanese sometimes runs ~1.5 chars/token
      tokenizer = Pikuri::VectorDb::Tokenizer::CharHeuristic.new(chars_per_token: 1.5)
      assert_equal 7, tokenizer.count('abcdefghij') # 10 / 1.5 = 6.67 → 7
    end

    it 'rejects non-positive values' do
      assert_raises(ArgumentError) do
        Pikuri::VectorDb::Tokenizer::CharHeuristic.new(chars_per_token: 0)
      end
      assert_raises(ArgumentError) do
        Pikuri::VectorDb::Tokenizer::CharHeuristic.new(chars_per_token: -1.0)
      end
    end
  end
end
