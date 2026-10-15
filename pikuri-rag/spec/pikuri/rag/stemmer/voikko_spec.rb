# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::Rag::Stemmer::Voikko do
  # Stands in for a +::Voikko+ handle, so the suite needs no libvoikko:
  # +analyses+ maps a word to its readings, each [base_form, [morpheme, ...]].
  def fake_voikko(analyses)
    analysis = Data.define(:base_form, :morphemes)
    morpheme = Data.define(:text)
    Object.new.tap do |voikko|
      voikko.define_singleton_method(:language) { 'fi' }
      voikko.define_singleton_method(:analyze) do |word|
        analyses.fetch(word, []).map do |base_form, parts|
          analysis.new(base_form, parts&.map { |text| morpheme.new(text) })
        end
      end
    end
  end

  let(:voikko) do
    fake_voikko(
      'kadun' => [['katu', ['kadun']], ['katua', ['kadun']]],
      'nokia' => [['noki', ['nokia']], ['Nokia', ['nokia']]],
      'tietokoneella' => [['tietokone', %w[tieto koneella]]],
      'tieto' => [['tieto', ['tieto']]],
      'koneella' => [['kone', ['koneella']]],
      'wikipediassa' => [['Wikipedia', %w[wiki pediassa]]],
      'wiki' => [['wiki', ['wiki']]],
      'katu' => [['katu', nil]]
    )
  end
  let(:stemmer) { described_class.new(voikko) }

  describe '#stems' do
    it 'answers every reading, lower-cased and distinct' do
      assert_equal %w[katu katua], stemmer.stems('kadun')
      assert_equal %w[noki nokia], stemmer.stems('nokia')
    end

    it 'answers an unknown word itself' do
      assert_equal ['backend'], stemmer.stems('backend')
    end

    # The query side never splits: "tietokone" searching for "kone" too
    # would make rag_find tietokone list every note mentioning kone.
    it 'leaves compounds whole' do
      assert_equal ['tietokone'], stemmer.stems('tietokoneella')
    end
  end

  describe '#index_stems' do
    it 'adds each compound part’s dictionary form after the whole' do
      assert_equal %w[tietokone tieto kone], stemmer.index_stems('tietokoneella')
    end

    it 'keeps a part that is no word alone as written' do
      assert_equal %w[wikipedia wiki pediassa], stemmer.index_stems('wikipediassa')
    end

    it 'adds nothing for a one-morpheme word or one with no STRUCTURE' do
      assert_equal %w[katu katua], stemmer.index_stems('kadun')
      assert_equal ['katu'], stemmer.index_stems('katu')
    end

    it 'answers an unknown word itself' do
      assert_equal ['backend'], stemmer.index_stems('backend')
    end

    it 'is #stems with compounds: false' do
      stemmer = described_class.new(voikko, compounds: false)
      assert_equal ['tietokone'], stemmer.index_stems('tietokoneella')
    end
  end

  describe '#id' do
    it 'names the language and the compound split, so changing either rebuilds the index' do
      assert_equal 'voikko-fi+compounds', stemmer.id
      assert_equal 'voikko-fi', described_class.new(voikko, compounds: false).id
    end
  end

  # The fake above is only as good as its likeness to the gem, so check the
  # same shapes against the real libvoikko where one is installed.
  describe 'against libvoikko' do
    let(:stemmer) do
      begin
        require 'voikko'
      rescue LoadError => e
        skip "no libvoikko here: #{e.message.lines.first}"
      end
      begin
        handle = ::Voikko.new(language: 'fi')
      rescue ::Voikko::Error => e
        skip "no voikko-fi here: #{e.message}"
      end
      described_class.new(handle)
    end

    it 'stems an inflected word and a lower-cased proper noun' do
      assert_equal ['katu'], stemmer.stems('kadulla')
      assert_equal ['helsinki'], stemmer.stems('helsingissä')
    end

    it 'splits a compound on the index side only' do
      assert_equal ['versionhallintajärjestelmä'], stemmer.stems('versionhallintajärjestelmää')
      assert_equal %w[versionhallintajärjestelmä versio hallinta järjestelmä],
                   stemmer.index_stems('versionhallintajärjestelmää')
    end

    it 'answers an unknown word itself' do
      assert_equal ['backend'], stemmer.index_stems('backend')
    end

    it 'names the handle’s language in its id' do
      assert_equal 'voikko-fi+compounds', stemmer.id
    end
  end
end
