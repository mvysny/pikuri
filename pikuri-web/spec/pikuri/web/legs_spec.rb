# frozen_string_literal: true

# Every web tool declares its legs by value, so the trifecta map grades what
# the tool actually does rather than the ASSUMED default.
RSpec.describe 'pikuri-web tool legs' do
  it 'gives the two page-fetchers exactly ASSUMED' do
    assert_equal Pikuri::Tool::TrifectaLegs::ASSUMED, Pikuri::Web::SCRAPE.trifecta_legs
    assert_equal Pikuri::Tool::TrifectaLegs::ASSUMED, Pikuri::Web::FETCH.trifecta_legs
  end

  it 'gives web_search a tool-vouched destination — the one web tool that has one' do
    # Nobody reviews the query, so the leg is unreviewed like fetch's; the whole
    # difference is where it can land. The engine set is this repo's own, so an
    # injection cannot steer the query at a host it can read back.
    tool = Pikuri::Web::Search.build(brave_key: nil, exa_key: nil)
    assert_equal :hard, tool.trifecta_legs.untrusted
    assert_equal :unreviewed, tool.trifecta_legs.egress_payload_review
    assert_equal :tool_vouched, tool.trifecta_legs.egress_destination
    assert_equal :attacker_reachable, Pikuri::Web::FETCH.trifecta_legs.egress_destination
  end

  it 'keeps the vouched destination when a host key adds a paid engine' do
    # The key picks *which* vouched engine, never a new destination — the claim
    # would be a lie if a host could point the search at an arbitrary host.
    tool = Pikuri::Web::Search.build(brave_key: 'k', exa_key: 'k')
    assert_equal :tool_vouched, tool.trifecta_legs.egress_destination
  end
end
