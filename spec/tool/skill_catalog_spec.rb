# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

require 'tool/skill_catalog'

RSpec.describe Tool::SkillCatalog do
  FIXTURE_ROOT = File.expand_path('../fixtures/skills', __dir__)

  # Capture warning log lines so collision / validation behavior can be
  # asserted instead of just observed in stderr. Pikuri's logger writes
  # through +Pikuri.log_io+; the spec_helper has already pointed that at
  # +/dev/null+, so we temporarily redirect to a +StringIO+ and restore.
  def with_captured_log_io
    captured = StringIO.new
    original = Pikuri.log_io
    Pikuri.log_io = captured
    yield captured.string.tap { captured }
  ensure
    Pikuri.log_io = original if original
  end

  def captured_log
    captured = StringIO.new
    original = Pikuri.log_io
    Pikuri.log_io = captured
    yield
    captured.string
  ensure
    Pikuri.log_io = original if original
  end

  describe Tool::SkillCatalog::EMPTY do
    it 'is the canonical empty singleton' do
      assert_kind_of Tool::SkillCatalog, described_class
      assert described_class.empty?
      assert_equal [], described_class.list
      assert_nil described_class.get('anything')
      assert_equal '', described_class.format_for_prompt
    end

    it 'is frozen' do
      assert described_class.frozen?
    end
  end

  describe Tool::SkillCatalog::Bundled do
    describe '#initialize with explicit roots' do
      it 'loads every SKILL.md under one root, sorted by directory name' do
        catalog = described_class.new(roots: [File.join(FIXTURE_ROOT, 'valid-tree')])

        names = catalog.list.map(&:name)
        # Dir.children is filesystem-ordered; the scanner sorts so the
        # registered order is deterministic for tests + prompt rendering.
        assert_equal %w[data-viz pdf-tools], names

        pdf = catalog.get('pdf-tools')
        assert_kind_of Tool::SkillCatalog::Skill, pdf
        assert_equal 'pdf-tools', pdf.name
        assert pdf.description.start_with?('Extracts text from PDF')
        assert pdf.body.include?('pdftotext')
        assert_equal File.join(FIXTURE_ROOT, 'valid-tree/pdf-tools/SKILL.md'),
                     pdf.location
      end

      it 'returns nil from #get for unknown names' do
        catalog = described_class.new(roots: [File.join(FIXTURE_ROOT, 'valid-tree')])
        assert_nil catalog.get('does-not-exist')
      end

      it 'skips skills with missing description (logs a warning)' do
        log = captured_log do
          catalog = described_class.new(roots: [File.join(FIXTURE_ROOT, 'missing-description-tree')])
          assert catalog.empty?
        end
        assert_match(/missing required 'description'/, log)
      end

      it 'skips files without YAML frontmatter (logs a warning)' do
        log = captured_log do
          catalog = described_class.new(roots: [File.join(FIXTURE_ROOT, 'no-frontmatter-tree')])
          assert catalog.empty?
        end
        assert_match(/no YAML frontmatter/, log)
      end

      it 'still loads a skill whose frontmatter name disagrees with the dir, with a warning' do
        log = captured_log do
          catalog = described_class.new(roots: [File.join(FIXTURE_ROOT, 'name-mismatch-tree')])
          assert_equal ['totally-different'], catalog.list.map(&:name)
        end
        assert_match(/does not match parent directory/, log)
      end

      it 'silently ignores a non-existent root' do
        log = captured_log do
          catalog = described_class.new(roots: ['/definitely/does/not/exist'])
          assert catalog.empty?
        end
        assert_equal '', log
      end

      it 'merges skills across multiple roots in the given order' do
        catalog = described_class.new(roots: [
          File.join(FIXTURE_ROOT, 'valid-tree'),
          File.join(FIXTURE_ROOT, 'name-mismatch-tree')
        ])
        assert_equal %w[data-viz pdf-tools totally-different].sort,
                     catalog.list.map(&:name).sort
      end

      it 'on a name collision keeps the first-listed root and logs a warning for the loser' do
        log = captured_log do
          catalog = described_class.new(roots: [
            File.join(FIXTURE_ROOT, 'collision-a'),
            File.join(FIXTURE_ROOT, 'collision-b')
          ])
          winner = catalog.get('pdf-tools')
          assert winner.description.include?('should win'),
                 "expected first-listed root to win, got description: #{winner.description.inspect}"
        end
        assert_match(/shadowed/, log)
        assert_match(/collision-b/, log)
      end
    end

    describe '#format_for_prompt' do
      it 'returns an empty string for an empty catalog' do
        catalog = described_class.new(roots: [])
        assert_equal '', catalog.format_for_prompt
      end

      it 'emits an <available_skills> block with name/description/location' do
        catalog = described_class.new(roots: [File.join(FIXTURE_ROOT, 'valid-tree')])
        out = catalog.format_for_prompt

        assert out.include?('<available_skills>'), out
        assert out.include?('</available_skills>'), out
        assert out.include?('<name>pdf-tools</name>'), out
        assert out.include?('<name>data-viz</name>'), out
        assert out.include?('<description>Extracts text from PDF'), out
        assert out.include?("<location>#{File.join(FIXTURE_ROOT, 'valid-tree/pdf-tools/SKILL.md')}</location>"), out
      end

      it 'escapes XML metacharacters in name/description/location' do
        Dir.mktmpdir do |root|
          dir = File.join(root, 'xml-skill')
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, 'SKILL.md'), <<~MD)
            ---
            name: xml-skill
            description: Watch <out> for "quotes" & ampersands.
            ---
            body
          MD

          catalog = described_class.new(roots: [root])
          out = catalog.format_for_prompt
          assert out.include?('&lt;out&gt;'), out
          assert out.include?('&quot;quotes&quot;'), out
          assert out.include?('&amp;'), out
        end
      end
    end

    describe '.discover' do
      it 'finds project skills under .pikuri/skills walking up to the git root' do
        Dir.mktmpdir do |repo|
          # Mark the dir as a git repo so the walk stops here.
          FileUtils.mkdir_p(File.join(repo, '.git'))
          skill_dir = File.join(repo, '.pikuri/skills/sample-skill')
          FileUtils.mkdir_p(skill_dir)
          File.write(File.join(skill_dir, 'SKILL.md'), <<~MD)
            ---
            name: sample-skill
            description: Project-scoped skill discovered via .discover.
            ---
            body
          MD

          nested = File.join(repo, 'src/deeply/nested')
          FileUtils.mkdir_p(nested)

          # Force HOME to a tmpdir that doesn't have any skills so the
          # global side of .discover is empty during this test.
          Dir.mktmpdir do |fake_home|
            original_home = ENV['HOME']
            ENV['HOME'] = fake_home
            begin
              catalog = described_class.discover(cwd: nested)
              assert_equal ['sample-skill'], catalog.list.map(&:name)
            ensure
              ENV['HOME'] = original_home
            end
          end
        end
      end

      it 'stops walking at the git root' do
        Dir.mktmpdir do |outer|
          # Outer dir has a skill that should NOT be discovered.
          outer_skill = File.join(outer, '.pikuri/skills/outer')
          FileUtils.mkdir_p(outer_skill)
          File.write(File.join(outer_skill, 'SKILL.md'), <<~MD)
            ---
            name: outer
            description: Outside the git root; must NOT be visible from inside.
            ---
            body
          MD

          # Inner subdir is its own git root.
          inner = File.join(outer, 'repo')
          FileUtils.mkdir_p(File.join(inner, '.git'))
          inner_skill = File.join(inner, '.pikuri/skills/inner')
          FileUtils.mkdir_p(inner_skill)
          File.write(File.join(inner_skill, 'SKILL.md'), <<~MD)
            ---
            name: inner
            description: Inside the git root; should be visible.
            ---
            body
          MD

          Dir.mktmpdir do |fake_home|
            original_home = ENV['HOME']
            ENV['HOME'] = fake_home
            begin
              catalog = described_class.discover(cwd: inner)
              names = catalog.list.map(&:name)
              assert_includes names, 'inner'
              refute_includes names, 'outer'
            ensure
              ENV['HOME'] = original_home
            end
          end
        end
      end

      it 'finds global skills under ~/.pikuri/skills' do
        Dir.mktmpdir do |fake_home|
          global_skill = File.join(fake_home, '.pikuri/skills/global-only')
          FileUtils.mkdir_p(global_skill)
          File.write(File.join(global_skill, 'SKILL.md'), <<~MD)
            ---
            name: global-only
            description: Lives only under ~ — discovery should pick it up.
            ---
            body
          MD

          Dir.mktmpdir do |cwd|
            # cwd has no project skill dirs.
            original_home = ENV['HOME']
            ENV['HOME'] = fake_home
            begin
              catalog = described_class.discover(cwd: cwd)
              assert_equal ['global-only'], catalog.list.map(&:name)
            ensure
              ENV['HOME'] = original_home
            end
          end
        end
      end

      it 'project skills take precedence over global skills with the same name' do
        Dir.mktmpdir do |fake_home|
          global_dir = File.join(fake_home, '.pikuri/skills/shared')
          FileUtils.mkdir_p(global_dir)
          File.write(File.join(global_dir, 'SKILL.md'), <<~MD)
            ---
            name: shared
            description: Global version — should lose to the project copy.
            ---
            body
          MD

          Dir.mktmpdir do |repo|
            FileUtils.mkdir_p(File.join(repo, '.git'))
            project_dir = File.join(repo, '.pikuri/skills/shared')
            FileUtils.mkdir_p(project_dir)
            File.write(File.join(project_dir, 'SKILL.md'), <<~MD)
              ---
              name: shared
              description: Project version — should win.
              ---
              body
            MD

            original_home = ENV['HOME']
            ENV['HOME'] = fake_home
            begin
              catalog = described_class.discover(cwd: repo)
              winner = catalog.get('shared')
              assert winner.description.include?('Project version'), winner.description
            ensure
              ENV['HOME'] = original_home
            end
          end
        end
      end
    end
  end
end
