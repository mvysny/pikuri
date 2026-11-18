# frozen_string_literal: true

RSpec.describe Pikuri::Fileindex::Query do
  def groups(text) = described_class.parse(text).groups

  it 'makes each bare word a group' do
    assert_equal [['rent'], ['lease'], ['vuokra']], groups(" rent lease\tvuokra ")
  end

  it 'makes the words in quotes one group' do
    assert_equal [%w[notice period], ['tenant']], groups('"notice period" tenant')
  end

  it 'runs a quote left open to the end' do
    assert_equal [['rent'], %w[due date]], groups('rent "due date')
  end

  it 'drops OR, AND, parentheses and tokens with no letter or digit' do
    assert_equal [['dental'], ['dentist'], ['Kettle'], ['Co'], %w[Kettle Co]],
                 groups('(dental OR dentist) and Kettle & Co "Kettle & Co"')
  end

  it 'keeps a group once' do
    assert_equal [['rent']], groups('rent rent "rent"')
  end

  it 'is empty when no word is left' do
    assert described_class.parse(' "" OR ( ) & ').empty?
  end

  it 'gathers every word, once, into one group for all_of' do
    assert_equal [%w[notice period tenant]], described_class.parse('"notice period" tenant notice').all_of.groups
  end

  it 'is frozen through' do
    query = described_class.parse('"a b" c')
    assert query.groups.frozen?
    assert query.groups.all?(&:frozen?)
  end
end
