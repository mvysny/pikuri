# frozen_string_literal: true

# Every bundled tool declares its legs by value. This is the tripwire the
# ASSUMED default needs: a new tool that forgets to declare is presumed hostile
# on both framework-knowable axes, which is right for safety and wrong for
# noise — a demo that goes loud over a calculator gets the advisory muted.
RSpec.describe 'bundled pikuri-core tool legs' do
  it 'gives the calculator no legs — pure arithmetic, no I/O' do
    assert_equal Pikuri::Tool::TrifectaLegs::NONE, Pikuri::Tool::CALCULATOR.trifecta_legs
  end

  it 'gives the two page-fetchers exactly ASSUMED' do
    assert_equal Pikuri::Tool::TrifectaLegs::ASSUMED, Pikuri::Tool::WEB_SCRAPE.trifecta_legs
    assert_equal Pikuri::Tool::TrifectaLegs::ASSUMED, Pikuri::Tool::FETCH.trifecta_legs
  end

  it 'gives web_search hard egress while :egress_searchengine does not exist' do
    # A search reaches a *pinned* sink, which is genuinely softer than an
    # attacker-chosen host — but grading it lower without the level in the
    # vocabulary would be a lie.
    tool = Pikuri::Tool::WebSearch.build(brave_key: nil, exa_key: nil)
    assert_equal :autonomous, tool.trifecta_legs.egress
    assert_equal :hard, tool.trifecta_legs.untrusted
  end

  it 'keeps a calculator-only agent silent' do
    node = Pikuri::Trifecta::Node.new(
      label: 'pikuri-chat',
      tool_legs: { 'calculator' => Pikuri::Tool::CALCULATOR.trifecta_legs }
    )
    assert_equal :silent, Pikuri::Trifecta.walk(node).tree_verdict
  end
end
