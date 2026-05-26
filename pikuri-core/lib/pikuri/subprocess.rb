# frozen_string_literal: true

require 'open3'
require 'set'

module Pikuri
  # Chokepoint for *all* subprocess spawning in pikuri. Forces a new
  # process group for each invocation, tracks pgids so descendants of
  # the direct child (commands backgrounded with +&+) can be cleaned
  # up at process exit, and captures combined stdout+stderr through a
  # single pipe.
  #
  # == Seam discipline
  #
  # All subprocess spawning in +lib/+ goes through {.spawn}. Direct
  # +Process.spawn+ / +Open3.*+ / +system+ / backticks anywhere in
  # +lib/+ are bugs. The convention is grep-enforceable:
  # +grep -rn 'Process\.spawn\|Open3\|system\|backtick' lib/+ should
  # only hit this file.
  #
  # == Timeouts are the caller's job
  #
  # {.spawn} does not implement a timeout — Ruby's +Timeout.timeout+
  # cannot kill subprocesses cleanly. Callers that need a timeout
  # wrap their argv with coreutils' +timeout+ binary:
  #
  #   Pikuri::Subprocess.spawn(
  #     'timeout', '--signal=TERM', '--kill-after=5s', '120s',
  #     'bash', '-c', command,
  #     chdir: workspace.cwd.to_s
  #   )
  #
  # When +timeout+ and its FD-inheriting children die, the combined
  # output pipe closes and {#wait}'s +io.read+ returns. No Ruby-side
  # timeout machinery; the +timeout+ binary handles SIGTERM-then-
  # SIGKILL race-free.
  #
  # == Backgrounded subprocesses
  #
  # When a shell command backgrounds work with +&+, the resulting
  # process stays in our pgroup. {#wait} returns as soon as the
  # direct child exits, but {.active} keeps the pgid in the tracked
  # set as long as any process in the group is alive (probed with
  # +kill(0, -pgid)+). On pikuri exit, {.cleanup!} sends SIGTERM to
  # every tracked group. The model can opt out via +nohup cmd &+ or
  # +setsid cmd &+ — both detach from our group.
  #
  # == State is process-global
  #
  # One +@active+ Set and one +at_exit+ for the whole process. A
  # +Mutex+ guards register/prune/cleanup; v1 is single-threaded, so
  # this is more for the +at_exit+/register race than for current
  # callers.
  #
  # == Why +Pikuri::Subprocess+, not top-level
  #
  # First class actually under the +Pikuri::+ namespace. Domain
  # classes (+Tool+, +Agent+, +URLCache+) are top-level as a legacy
  # convention — they predate the namespacing decision and an
  # eventual refactor moves them too. For now: library-level
  # infrastructure under +Pikuri::+; domain objects flat. See
  # +CLAUDE.md+ for the convention.
  class Subprocess
    # Combined output + exit status, returned from {#wait}.
    Result = Data.define(:output, :status)

    # Spawn +argv+ in a new process group, redirecting stderr onto
    # stdout. Tracked for cleanup.
    #
    # @param argv [Array<String>] command and arguments. Caller does
    #   any shell wrapping (e.g. +'bash', '-c', cmd+) when shell
    #   interpretation is wanted; +argv+ is passed to +exec+
    #   directly, so no implicit shell expansion happens here.
    # @param chdir [String, Pathname] working directory
    # @param env [Hash{String=>String}] extra environment variables to
    #   set in the child process. The child otherwise inherits the
    #   parent's full environment; entries in +env+ override or add to
    #   it. Default +{}+ (pure inheritance). Used by {Code::Bash} to
    #   thread {Pikuri::Workspace::Filesystem#env} (host git identity,
    #   etc.) into a bash subprocess whose sandbox would otherwise
    #   strip the host's config files.
    # @return [Subprocess] handle — call {#wait} to block for the
    #   direct child to exit and read the captured output
    def self.spawn(*argv, chdir:, env: {})
      stdin, io, wait_thr = Open3.popen2e(env, *argv, chdir: chdir.to_s, pgroup: true)
      stdin.close
      register(wait_thr.pid)
      new(io: io, wait_thr: wait_thr)
    end

    # @return [Integer] direct child's pid
    attr_reader :pid

    # @return [Integer] process group id. Equal to {#pid} since the
    #   child was spawned with +pgroup: true+ (it's the group leader).
    attr_reader :pgid

    # @return [IO] read end of the combined stdout+stderr pipe.
    #   Exposed for future live-streaming consumers; v1 callers go
    #   straight to {#wait}, which drains it.
    attr_reader :io

    # @api private — call {.spawn}, not the constructor.
    def initialize(io:, wait_thr:)
      @io       = io
      @wait_thr = wait_thr
      @pid      = wait_thr.pid
      @pgid     = wait_thr.pid # pgroup:true → pgid == pid
    end

    # Block until the direct child exits, read whatever remains on
    # the combined-output pipe, return a {Result}. The pgid stays
    # tracked if the group still has live members (backgrounded
    # children); pruned if everything's gone.
    #
    # @return [Result]
    def wait
      output = @io.read
      @io.close
      Result.new(output: output, status: @wait_thr.value)
    ensure
      self.class.send(:prune, @pgid)
    end

    class << self
      # Currently-tracked process groups, with dead ones pruned as a
      # side effect. Useful for a future +/bg+ REPL command or a
      # between-turn status line.
      #
      # @return [Array<Integer>]
      def active
        @mutex.synchronize do
          @active.delete_if { |g| !alive?(g) }
          @active.to_a
        end
      end

      # SIGTERM every tracked process group. Used by +at_exit+
      # (production) and +after+ blocks (specs). Best-effort —
      # ignores errors from already-dead groups.
      #
      # @return [void]
      def cleanup!
        @mutex.synchronize do
          @active.each { |g| Process.kill('-TERM', g) rescue nil }
          @active.clear
        end
      end

      private

      def register(pgid)
        @mutex.synchronize { @active << pgid }
      end

      def prune(pgid)
        @mutex.synchronize { @active.delete(pgid) unless alive?(pgid) }
      end

      def alive?(pgid)
        Process.kill(0, -pgid)
        true
      rescue Errno::ESRCH
        false
      end
    end

    @active = Set.new
    @mutex  = Mutex.new
  end
end

at_exit { Pikuri::Subprocess.cleanup! }
