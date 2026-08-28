# frozen_string_literal: true

# Executable form of the grep tripwires CLAUDE.md's seams declare.
#
# These used to live in CLAUDE.md as literal shell one-liners next to the
# invariant each one guards. That put ~2 KB of shell into a file loaded
# every session, and — worse — nothing ever ran them, so they rotted
# silently: when this file was first written, two were already wrong
# (T_subprocess_chokepoint named +code/bash.rb+, which had stopped
# matching, and missed three files that had started; T_walked_path_denylist
# named +Search::Grep+, which filters by prefix through
# +Utils.reject_denied_lines+ rather than calling +denied?+).
#
# So CLAUDE.md now states the invariant and cites the slug, and the
# command lives here where +rake tripwires+ runs it. A tripwire that fails
# is either a real violation or a stale expectation — both worth a human
# looking, which is why a failure prints the offending lines rather than
# just a count.
#
# Checks are cited by slug (+T_<name>+), the same convention DECISIONS.md
# uses for +D_+. Ids are stable once published: rename only with a sweep
# of every reference.
#
# Runs in CI after +rake test+ (see +.woodpecker.yml+), so every check must
# either report or raise — never pass vacuously.
require 'open3'

module Tripwires
  # One check. +body+ returns an Array of violation strings (empty = pass).
  Check = Struct.new(:id, :invariant, :body) do
    def run = body.call
  end

  # Ruby comments are not code. Several invariants are about what the code
  # *does*, and a yardoc example naming +Open3.popen3+ is documentation of
  # the very rule it appears to break — so those checks read code lines
  # only. Deliberately naive: a line whose first non-space character is
  # +#+. A +#+ inside a string or heredoc still counts as code, which errs
  # toward reporting rather than hiding.
  def self.code_lines(path)
    File.readlines(path, chomp: true).each_with_index.reject do |line, _i|
      line.lstrip.start_with?('#')
    end
  end

  def self.all_lines(path)
    File.readlines(path, chomp: true).each_with_index.to_a
  end

  # Every +.rb+ under every gem's +lib/+.
  def self.lib_files
    Dir.glob('pikuri-*/lib/**/*.rb').sort
  end

  # Files git tracks, for the repo-wide prose checks. +git ls-files+ rather
  # than a glob so the scan matches what is actually committed and skips
  # +.git/+, build artifacts and untracked scratch files.
  #
  # Raises rather than degrading. An empty list would make every check
  # built on it pass vacuously — the one outcome worse than a red tripwire
  # is a green one that scanned nothing, and this runs in CI where no human
  # is reading the output of a passing build.
  def self.tracked_files
    @tracked_files ||= begin
      out, status = Open3.capture2e('git', 'ls-files', '-z')
      raise "git ls-files failed (#{status.exitstatus}): #{out}" unless status.success?

      files = out.split("\0").reject(&:empty?)
      raise 'git ls-files returned nothing — is this a git checkout?' if files.empty?

      files
    end
  end

  # "path:line: text" for every line matching +pattern+.
  def self.hits(pattern, files:, code_only: false)
    files.flat_map do |path|
      next [] unless File.file?(path)

      lines = code_only ? code_lines(path) : all_lines(path)
      lines.filter_map do |line, index|
        "#{path}:#{index + 1}: #{line.strip}" if line.match?(pattern)
      end
    end
  end

  # Violations = hits whose path is not in +allowed+.
  def self.confined(pattern, allowed:, files: lib_files, code_only: false)
    hits(pattern, files: files, code_only: code_only).reject do |hit|
      path = hit.split(':', 2).first
      allowed.any? { |ok| path == ok || path.start_with?(ok) }
    end
  end

  # Slugs matching +pattern+ cited anywhere in +files+ but never defined as
  # a heading in +doc+.
  #
  # +pattern+ must capture the slug first and a trailing +*+ second: prose
  # cites a whole family as a glob (+D_lsp_*+, +D_history_*+), which is not
  # a dangling reference. Detecting the star beats listing every family,
  # which would need editing each time prose names a new one.
  #
  # +placeholders+ is for text that looks like a slug and is not — today
  # only +D_xxx+, the stand-in in CLAUDE.md's CHANGELOG rule.
  def self.dangling_slugs(pattern, heading:, doc:, files:, placeholders: [])
    cited = files.select { |f| File.file?(f) }
                 .flat_map { |f| File.read(f, encoding: 'UTF-8').scan(pattern) }
                 .reject { |_slug, glob| glob == '*' }
                 .map(&:first).uniq - placeholders
    defined = File.read(doc).scan(heading).flatten.uniq
    (cited - defined).sort.map { |slug| "#{slug} — cited but no heading in #{doc}" }
  end

  CHECKS = [
    Check.new(
      'T_extraction_registry',
      'Every format→text conversion routes through the Extractor registry.',
      -> {
        confined(/require '(pdf-reader|readability|reverse_markdown)'/,
                 allowed: ['pikuri-core/lib/pikuri/extractor/', 'pikuri-pdf/lib/'])
      }
    ),

    Check.new(
      'T_subprocess_chokepoint',
      'All subprocess spawning in lib/ routes through Subprocess.spawn, ' \
      'except two long-lived stdio children.',
      # Only two paths are allowed, though CLAUDE.md names three
      # exceptions: the MCP child is spawned *inside* the third-party
      # +mcp+ gem (+MCP::Client::Stdio+), so pikuri's own
      # +mcp/client_wrapper.rb+ contains no spawn primitive to match.
      -> {
        confined(/Process\.spawn|Open3\.|\bsystem\(/,
                 allowed: ['pikuri-core/lib/pikuri/subprocess.rb',
                           'pikuri-lsp/lib/pikuri/lsp/client_wrapper.rb'],
                 code_only: true)
      }
    ),

    Check.new(
      'T_single_at_exit',
      'One process-global teardown registry, single at_exit.',
      -> { confined(/at_exit \{/, allowed: ['pikuri-core/lib/pikuri/finalizers.rb']) }
    ),

    Check.new(
      'T_listener_emit',
      'Only the Agent and its ExtensionContext emit on the listener list.',
      -> {
        confined(/listeners\.emit/,
                 allowed: ['pikuri-core/lib/pikuri/agent.rb',
                           'pikuri-core/lib/pikuri/agent/extension_context.rb'],
                 code_only: true)
      }
    ),

    Check.new(
      'T_walked_path_denylist',
      'Every enumerating tool filters its own results against the denylist.',
      # The roster of files allowed to *perform* the walked-path filter.
      # Grep is here via +reject_denied_lines+ (a prefix filter over rg
      # output) rather than a per-path +denied?+ call — same guarantee,
      # different mechanism, which is why the pattern is a union.
      -> {
        confined(/denied\?|denied_roots|reject_denied_lines/,
                 allowed: ['pikuri-workspace/lib/pikuri/workspace/filesystem.rb',
                           'pikuri-workspace/lib/pikuri/workspace/listing.rb',
                           'pikuri-workspace/lib/pikuri/workspace/search/glob.rb',
                           'pikuri-workspace/lib/pikuri/workspace/search/grep.rb',
                           'pikuri-workspace/lib/pikuri/workspace/search/utils.rb',
                           'pikuri-lsp/lib/pikuri/lsp/sources.rb',
                           'pikuri-lsp/lib/pikuri/lsp/renderer.rb'],
                 code_only: true)
      }
    ),

    Check.new(
      'T_lsp_denied_sites',
      'In pikuri-lsp, only Sources and the Renderer consult denied?.',
      -> {
        confined(/denied\?/,
                 allowed: ['pikuri-lsp/lib/pikuri/lsp/sources.rb',
                           'pikuri-lsp/lib/pikuri/lsp/renderer.rb'],
                 files: Dir.glob('pikuri-lsp/lib/**/*.rb').sort,
                 code_only: true)
      }
    ),

    Check.new(
      'T_lsp_finding_ids',
      'Every LSP finding id cited in the repo is defined in pikuri-lsp/DESIGN.md.',
      -> {
        dangling_slugs(/\b([FJHS]_[a-z0-9_]+)(\*?)/,
                       heading: /\*\*([FJHS]_[a-z0-9_]+)\.\*\*/,
                       doc: 'pikuri-lsp/DESIGN.md',
                       files: tracked_files.grep(%r{^(pikuri-lsp/|bin/)}))
      }
    ),

    Check.new(
      'T_command_not_advertised',
      'A slash command is never advertised — no prompt snippet, no tool.',
      -> {
        lib_files.select { |f| File.read(f).include?('Command::Registry') }
                 .select { |f| File.read(f).match?(/system_prompt_snippets|add_tool/) }
                 .map { |f| "#{f}: names Command::Registry alongside an advertising call" }
      }
    ),

    Check.new(
      'T_no_system_role',
      'Nothing pikuri appends mid-conversation is ever role: :system.',
      -> {
        hits(/add_message\(role: :system/, files: lib_files) +
          confined(/add_message\(role:/, allowed: ['pikuri-core/lib/pikuri/agent.rb'])
      }
    ),

    Check.new(
      'T_history_encapsulated',
      'A conversation leaves the agent only as a History; no host reads @chat.messages.',
      -> { confined(/@chat\.messages/, allowed: ['pikuri-core/lib/pikuri/agent.rb']) }
    ),

    Check.new(
      'T_thunderbird_no_attachment',
      'No attachment ever ships on an outbound Thunderbird hand-off.',
      -> {
        base = 'pikuri-thunderbird/lib/pikuri/thunderbird'
        files = %w[mailto_uri ics_event mail_compose calendar_create launcher]
                .map { |n| "#{base}/#{n}.rb" }
        hits(/attach/i, files: files)
      }
    ),

    Check.new(
      'T_tool_sharing_posture',
      'Every file defining a Pikuri::Tool subclass declares a sharing posture.',
      -> {
        lib_files.select { |f| File.read(f).match?(/^\s*class\s+\w+\s*<\s*(Pikuri::)?Tool\b/) }
                 .reject { |f| File.read(f).include?('Sharing') }
                 .map { |f| "#{f}: defines a Tool subclass with no Sharing line" }
      }
    ),

    Check.new(
      'T_paths_xdg',
      'Cache and temp paths go through Paths, never ENV directly.',
      -> {
        confined(/ENV\['XDG_CACHE_HOME'\]/,
                 allowed: ['pikuri-core/lib/pikuri/paths.rb'])
      }
    ),

    Check.new(
      'T_no_tool_names_in_prompts',
      'A main/binary system prompt names no wired pikuri tool.',
      # Persona prompts are the carve-out: tool_names: and system_prompt:
      # are co-located there, so they may name their tools.
      -> {
        tools = %w[bash write read grep glob file_list edit agent calculator
                   web_search web_scrape fetch recall skill mcp_connect].join('|')
        pattern = /`(#{tools}|task_[a-z]+|vectordb_[a-z]+)`/
        files = Dir.glob('*/prompts/*.txt').reject { |f| File.basename(f).start_with?('persona-') }
        hits(pattern, files: files.sort)
      }
    ),

    Check.new(
      'T_named_chapters',
      'Book chapters are referenced by name, never by ordinal or numbered filename.',
      -> {
        hits(/chapters? ?\d+|\bch\.? ?\d+\b/i, files: tracked_files) +
          hits(/\d{2}-[a-z-]+\.md/, files: tracked_files)
      }
    ),

    Check.new(
      'T_decision_slugs',
      'Every D_ slug cited in the repo exists as a heading in DECISIONS.md.',
      -> {
        dangling_slugs(/\b(D_[a-z0-9_]+)(\*?)/,
                       heading: /^## (D_[a-z0-9_]+)/,
                       doc: 'DECISIONS.md',
                       files: tracked_files,
                       placeholders: %w[D_xxx])
      }
    )
  ].freeze
end

desc 'Check the grep tripwires CLAUDE.md\'s seams declare (T_<slug> ids)'
task :tripwires do
  width = Tripwires::CHECKS.map { |c| c.id.length }.max
  failures = {}

  Tripwires::CHECKS.each do |check|
    # +uniq+ because a check built from two patterns can match one line
    # twice (T_no_system_role's narrow and broad +add_message+ passes),
    # and one offending line should be reported once.
    violations = check.run.uniq
    status = violations.empty? ? 'ok' : "FAIL (#{violations.size})"
    puts "  #{check.id.ljust(width)}  #{status}"
    failures[check] = violations unless violations.empty?
  end

  if failures.empty?
    puts "\n#{Tripwires::CHECKS.size} tripwires hold."
    next
  end

  # Print the offending data, not just a count: a tripwire failure is as
  # often a stale expectation as a real violation, and telling them apart
  # needs the lines.
  failures.each do |check, violations|
    puts "\n==> #{check.id}"
    puts "    #{check.invariant}"
    violations.each { |v| puts "      #{v}" }
  end

  raise "#{failures.size} of #{Tripwires::CHECKS.size} tripwires failed: " \
        "#{failures.keys.map(&:id).join(', ')}"
end
