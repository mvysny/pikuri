# frozen_string_literal: true

RSpec.describe 'skill tool trifecta legs' do
  it 'is hard untrusted — a skill is a file someone else wrote, loaded verbatim' do
    tool = Pikuri::Skill::SkillTool.new(catalog: Pikuri::Skill::Catalog::EMPTY)
    assert_equal :hard, tool.trifecta_legs.untrusted
  end

  it 'has no egress leg and claims no private pool' do
    tool = Pikuri::Skill::SkillTool.new(catalog: Pikuri::Skill::Catalog::EMPTY)
    assert_equal :no_egress, tool.trifecta_legs.egress_payload_review
    refute tool.trifecta_legs.private
  end
end
