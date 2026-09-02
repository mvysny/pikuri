# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::Rag::Query do
  describe '.tokenize' do
    it 'splits on letter/digit runs and lower-cases' do
      assert_equal %w[acme s q3 pricing v2 1],
                   Pikuri::Rag::Query.tokenize("Acme's Q3 pricing — v2.1")
    end

    it 'keeps non-Latin letters' do
      assert_equal %w[schrödinger ужин], Pikuri::Rag::Query.tokenize('Schrödinger, ужин')
    end

    it 'returns empty for punctuation-only and nil input' do
      assert_equal [], Pikuri::Rag::Query.tokenize('--- ?! ***')
      assert_equal [], Pikuri::Rag::Query.tokenize(nil)
    end
  end

  describe '.terms' do
    it 'returns one quoted phrase term per word' do
      assert_equal ['"acme"', '"pricing"'], Pikuri::Rag::Query.terms('Acme pricing')
    end

    # Not the juxtaposed '"acme" "pricing"' FTS5 reads as an implicit AND:
    # that AND is row-scoped, and a row is a chunk. The caller ANDs across
    # the document instead.
    it 'never joins the terms into one expression' do
      assert_equal 2, Pikuri::Rag::Query.terms('Acme pricing').length
      refute Pikuri::Rag::Query.respond_to?(:all), 'the chunk-scoped AND form must not come back'
    end

    it 'is empty when nothing is searchable' do
      assert_equal [], Pikuri::Rag::Query.terms('   ')
      assert_equal [], Pikuri::Rag::Query.terms('%%%')
    end
  end

  describe '.any' do
    it 'ORs quoted phrase terms' do
      assert_equal '"what" OR "did" OR "we" OR "discuss"',
                   Pikuri::Rag::Query.any('What did we discuss?')
    end

    it 'is nil when nothing is searchable' do
      assert_nil Pikuri::Rag::Query.any('!!!')
    end
  end

  describe 'FTS5 operators are never exposed' do
    it 'quotes OR as a literal term rather than an operator' do
      assert_equal ['"acme"', '"or"', '"initech"'], Pikuri::Rag::Query.terms('acme OR initech')
    end

    it 'neutralizes prefix stars, column filters and grouping' do
      assert_equal ['"acme"', '"near"', '"text"', '"pricing"'],
                   Pikuri::Rag::Query.terms('acme NEAR* {text}: pricing')
    end

    it 'strips a leading hyphen rather than emitting a syntax error' do
      assert_equal ['"acme"'], Pikuri::Rag::Query.terms('-acme')
    end

    # The one input that could survive tokenizing as syntax: a quote. It
    # cannot, because a term is emitted as a phrase with internal quotes
    # doubled — but tokenizing already dropped it, which is the belt to
    # that braces.
    it 'never emits an unbalanced quote' do
      terms = Pikuri::Rag::Query.terms('say "hello" AND 1=1')
      terms.each { |t| assert_equal 0, t.count('"') % 2 }
      assert_equal ['"say"', '"hello"', '"and"', '"1"', '"1"'], terms
    end
  end
end
