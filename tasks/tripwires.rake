# frozen_string_literal: true

# Executable form of the handful of seams that break *silently*.
#
# The set is closed at five. *Do not add a +T_+ rule* — a new invariant
# goes in AGENTS.md as prose and stays unchecked. The bar the five clear:
# breaking the seam is *invisible* (every spec stays green, the diff looks
# reasonable) and the consequence is a security hole or a protocol
# failure, not an untidy file; a grep says so in one line, over +lib/+
# only. Eighteen of these once accumulated into a checker framework —
# which were cut and why are +design/decisions.md+ +D_tripwire_bar+.
#
# The doc layer is not our business: slug links, file caps and the shim
# files belong to +design/verify_design_tripwires.sh+, which runs beside
# this file in +rake check+. It checks both directions, so a check added
# here that nothing cites fails just as a cited id with no check does.
#
# A failure is as often a stale expectation as a real violation, which is
# why it prints the offending lines rather than a count. Ids are stable
# once published: rename only with a sweep of every reference.
module Tripwires
  # One check. +body+ returns an Array of violation strings (empty = pass).
  Check = Struct.new(:id, :invariant, :body) do
    def run = body.call
  end

  # Every +.rb+ under every gem's +lib/+ — the only thing these scan.
  # A convention about prose, prompts or docs is not a tripwire any more.
  def self.lib_files
    Dir.glob('pikuri-*/lib/**/*.rb').sort
  end

  # "path:line: text" for every *code* line matching +pattern+.
  #
  # Ruby comments are not code. Every invariant here is about what the code
  # *does*, and a yardoc example naming +Open3.popen3+ is documentation of
  # the very rule it appears to break. Deliberately naive: a line whose
  # first non-space character is +#+ is skipped. A +#+ inside a string or
  # heredoc still counts as code, which errs toward reporting.
  def self.hits(pattern)
    lib_files.flat_map do |path|
      File.readlines(path, chomp: true).each_with_index.filter_map do |line, index|
        next if line.lstrip.start_with?('#')

        "#{path}:#{index + 1}: #{line.strip}" if line.match?(pattern)
      end
    end
  end

  # Violations = hits whose path is not in +allowed+.
  def self.confined(pattern, allowed:)
    hits(pattern).reject do |hit|
      path = hit.split(':', 2).first
      allowed.any? { |ok| path == ok || path.start_with?(ok) }
    end
  end

  CHECKS = [
    Check.new(
      'T_subprocess_chokepoint',
      'All subprocess spawning in lib/ routes through Subprocess.spawn, ' \
      'except two long-lived stdio children.',
      # Two sanctioned exceptions (stated in +pikuri-mcp/AGENTS.md+ /
      # +pikuri-lsp/AGENTS.md+), but only one path to allow: the MCP child
      # is spawned *inside* the third-party +mcp+ gem
      # (+MCP::Client::Stdio+), so pikuri's own +mcp/client_wrapper.rb+
      # contains no spawn primitive to match.
      -> {
        confined(/Process\.spawn|Open3\.|\bsystem\(/,
                 allowed: ['pikuri-core/lib/pikuri/subprocess.rb',
                           'pikuri-lsp/lib/pikuri/lsp/client_wrapper.rb'])
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
                           'pikuri-lsp/lib/pikuri/lsp/renderer.rb'])
      }
    ),

    Check.new(
      'T_request_permits',
      'Every ruby_llm request rides a Context whose instrumenter is the permit gate.',
      # Two halves of one seam, both of which a plausible tidy-up breaks
      # silently — the throttle would simply stop gating, with every spec
      # still green. A +RubyLLM.chat+ call is a chat built off the *global*
      # config, i.e. one carrying no throttle; and the +instrumenter+ slot is
      # single-occupancy, so anything else assigning it displaces the gate
      # (a host's own instrumenter is chained *by* the gate, not installed
      # over it).
      -> {
        hits(/RubyLLM\.chat\b/) +
          confined(/instrumenter\s*=[^=]/, allowed: ['pikuri-core/lib/pikuri/agent.rb'])
      }
    ),

    Check.new(
      'T_no_system_role',
      'Nothing pikuri appends mid-conversation is ever role: :system.',
      # The definitive silent failure: a mid-conversation +:system+ message
      # is accepted, sent, and ignored by the model. Nothing goes red.
      -> {
        hits(/add_message\(role: :system/) +
          confined(/add_message\(role:/, allowed: ['pikuri-core/lib/pikuri/agent.rb'])
      }
    ),

    Check.new(
      'T_single_at_exit',
      'One process-global teardown registry, single at_exit.',
      # A second +at_exit+ tears down in an order nobody chose, and only
      # sometimes — the failure surfaces as a stray temp dir or an orphaned
      # child on one machine.
      -> { confined(/at_exit \{/, allowed: ['pikuri-core/lib/pikuri/finalizers.rb']) }
    )
  ].freeze
end

desc 'Check the five silent-failure tripwires AGENTS.md declares (T_<slug> ids)'
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
