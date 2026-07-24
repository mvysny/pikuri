# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

RSpec.describe Pikuri::Skill::Renderer do
  RENDERER_FIXTURE_ROOT = File.expand_path('../../fixtures/skills', __dir__)

  # Build a Catalog::Skill directly, so a render can be exercised without a
  # SKILL.md on disk (used for the metacharacter-escaping cases).
  def skill(name:, location:, description: 'desc', body: 'body')
    Pikuri::Skill::Catalog::Skill.new(
      name: name, description: description, location: location, body: body
    )
  end

  describe '.format_catalog' do
    it 'returns an empty string for an empty catalog' do
      assert_equal '', described_class.format_catalog(Pikuri::Skill::Catalog::EMPTY)
    end

    it 'emits an <available_skills> block with name/description/location' do
      catalog = Pikuri::Skill::Catalog::Bundled.new(
        search_bases: [File.join(RENDERER_FIXTURE_ROOT, 'valid-tree')]
      )
      out = described_class.format_catalog(catalog)

      assert out.include?('<available_skills>'), out
      assert out.include?('</available_skills>'), out
      assert out.include?('<name>pdf-tools</name>'), out
      assert out.include?('<name>data-viz</name>'), out
      assert out.include?('<description>Extracts text from PDF'), out
      assert out.include?(
        "<location>#{File.join(RENDERER_FIXTURE_ROOT, 'valid-tree/.pikuri/skills/pdf-tools/SKILL.md')}</location>"
      ), out
    end

    it 'escapes XML metacharacters in name/description/location' do
      Dir.mktmpdir do |base|
        dir = File.join(base, '.pikuri/skills/xml-skill')
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, 'SKILL.md'), <<~MD)
          ---
          name: xml-skill
          description: Watch <out> for "quotes" & ampersands.
          ---
          body
        MD

        catalog = Pikuri::Skill::Catalog::Bundled.new(search_bases: [base])
        out = described_class.format_catalog(catalog)
        assert out.include?('&lt;out&gt;'), out
        assert out.include?('&quot;quotes&quot;'), out
        assert out.include?('&amp;'), out
      end
    end
  end

  describe '.format_skill' do
    it 'wraps the body with the name, location and sidecar base directory' do
      out = described_class.format_skill(
        skill(name: 'pdf-tools', location: '/repo/.pikuri/skills/pdf-tools/SKILL.md', body: 'run pdftotext')
      )

      assert out.include?('<skill name="pdf-tools" location="/repo/.pikuri/skills/pdf-tools/SKILL.md">'), out
      assert out.include?('relative to /repo/.pikuri/skills/pdf-tools.'), out
      assert out.include?('run pdftotext'), out
      assert out.include?('</skill>'), out
    end

    it 'escapes XML metacharacters in the wrapper name/location attributes' do
      out = described_class.format_skill(
        skill(name: 'weird"<name>', location: '/tmp/a&b/SKILL.md')
      )

      assert out.include?('name="weird&quot;&lt;name&gt;"'), out
      assert out.include?('location="/tmp/a&amp;b/SKILL.md"'), out
    end

    it 'leaves the body verbatim (not XML-escaped)' do
      out = described_class.format_skill(
        skill(name: 'x', location: '/x/SKILL.md', body: 'if a < b && c > d then')
      )

      assert out.include?('if a < b && c > d then'), out
    end
  end
end
