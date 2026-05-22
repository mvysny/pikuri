# frozen_string_literal: true

# Top-level Rakefile for the pikuri monorepo. The release task bumps
# every gem's VERSION constant in lockstep, builds each gem, and
# pushes each to rubygems.org — same shape Rails (rails/rails) uses
# for its multi-gem monorepo.
#
# Gem list grows as Phase 2 of the gem-split refactor lands more
# extractions. Each entry maps directory name → gem name. The two
# are usually identical (e.g. pikuri-skills/ → pikuri-skills); the
# core gem is the one exception (pikuri-core/ → pikuri-core, but the
# convenience metagem at pikuri/ is also named +pikuri+).
GEMS = {
  'pikuri-core'   => 'pikuri-core',
  'pikuri-skills' => 'pikuri-skills',
  'pikuri-mcp'    => 'pikuri-mcp'
}.freeze

# Path to the single source of truth for the shared version constant.
# Every release bumps this one file; the per-gem gemspec files all
# read +Pikuri::VERSION+ via +require_relative+, so they pick up the
# new value automatically.
VERSION_FILE = File.expand_path('pikuri-core/lib/pikuri/version.rb', __dir__).freeze

# Run rspec inside each gem dir. `bundle exec rake test` from the
# repo root fans out so the whole monorepo's tests run in one shot.
desc 'Run specs across every gem in the monorepo'
task :test do
  failed = []
  GEMS.each_key do |dir|
    next unless Dir.exist?(File.join(dir, 'spec'))

    puts "\n==> #{dir}"
    ok = system("cd #{dir} && bundle exec rspec")
    failed << dir unless ok
  end
  raise "Specs failed in: #{failed.join(', ')}" unless failed.empty?
end

task default: :test

# Lockstep release: bump → build → push → tag.
#
# Usage: VERSION=1.2.3 rake release
#
# 1. Rewrites VERSION_FILE with the new version (single source of
#    truth read by every gemspec).
# 2. In each gem directory, `gem build *.gemspec` to produce a .gem
#    file.
# 3. `gem push` each .gem to rubygems.org.
# 4. git tag the commit + push.
#
# Pre-flight: git working tree must be clean. We tag the commit
# that exists *before* this task runs; the version bump itself is
# the commit being released. The convention follows Rails: bump
# version, commit "vX.Y.Z", run rake release.
desc 'Lockstep release: bump → build → push → tag (set VERSION=x.y.z)'
task :release do
  version = ENV.fetch('VERSION') do
    raise 'Set VERSION=x.y.z to release'
  end

  unless `git status --porcelain`.strip.empty?
    raise 'Working tree must be clean before release. Commit or stash changes.'
  end

  puts "==> Bumping VERSION constant to #{version}"
  text = File.read(VERSION_FILE)
  bumped = text.sub(/VERSION\s*=\s*['"][^'"]+['"]/, "VERSION = '#{version}'")
  raise "VERSION constant not found in #{VERSION_FILE}" if bumped == text

  File.write(VERSION_FILE, bumped)
  system('git', 'add', VERSION_FILE) || raise('git add failed')
  system('git', 'commit', '-m', "v#{version}") || raise('git commit failed')

  GEMS.each_key do |dir|
    puts "\n==> Building + pushing #{dir}"
    Dir.chdir(dir) do
      system('rm', '-f', *Dir.glob('*.gem'))
      system('gem', 'build', *Dir.glob('*.gemspec')) || raise("gem build failed in #{dir}")
      gem_file = Dir.glob('*.gem').first
      raise "no .gem built in #{dir}" unless gem_file

      system('gem', 'push', gem_file) || raise("gem push failed for #{gem_file}")
    end
  end

  system('git', 'tag', "v#{version}") || raise('git tag failed')
  puts "\nReleased v#{version}. Push the tag with: git push && git push --tags"
end
