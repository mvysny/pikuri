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

  it 'gives web_search a tool-vouched destination — the one bundled tool that has one' do
    # Nobody reviews the query, so the leg is unreviewed like fetch's; the whole
    # difference is where it can land. The engine set is this repo's own, so an
    # injection cannot steer the query at a host it can read back.
    tool = Pikuri::Tool::WebSearch.build(brave_key: nil, exa_key: nil)
    assert_equal :hard, tool.trifecta_legs.untrusted
    assert_equal :unreviewed, tool.trifecta_legs.egress_payload_review
    assert_equal :tool_vouched, tool.trifecta_legs.egress_destination
    assert_equal :attacker_reachable, Pikuri::Tool::FETCH.trifecta_legs.egress_destination
  end

  it 'keeps the vouched destination when a host key adds a paid engine' do
    # The key picks *which* vouched engine, never a new destination — the claim
    # would be a lie if a host could point the search at an arbitrary host.
    tool = Pikuri::Tool::WebSearch.build(brave_key: 'k', exa_key: 'k')
    assert_equal :tool_vouched, tool.trifecta_legs.egress_destination
  end

  it 'keeps a calculator-only agent silent' do
    node = Pikuri::Trifecta::Node.new(
      label: 'pikuri-chat',
      tool_legs: { 'calculator' => Pikuri::Tool::CALCULATOR.trifecta_legs }
    )
    assert_equal :silent, Pikuri::Trifecta.walk(node).tree_verdict
  end
end
