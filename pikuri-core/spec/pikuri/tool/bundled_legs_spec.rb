# frozen_string_literal: true

# Every bundled tool declares its legs by value. This is the tripwire the
# ASSUMED default needs: a new tool that forgets to declare is presumed hostile
# on both framework-knowable axes, which is right for safety and wrong for
# noise — a demo that goes loud over a calculator gets the advisory muted.
RSpec.describe 'bundled pikuri-core tool legs' do
  it 'gives the calculator no legs — pure arithmetic, no I/O' do
    assert_equal Pikuri::Tool::TrifectaLegs::NONE, Pikuri::Tool::CALCULATOR.trifecta_legs
  end

  it 'keeps a calculator-only agent silent' do
    node = Pikuri::Trifecta::Node.new(
      label: 'pikuri-chat',
      tool_legs: { 'calculator' => Pikuri::Tool::CALCULATOR.trifecta_legs }
    )
    assert_equal :silent, Pikuri::Trifecta.walk(node).tree_verdict
  end
end
