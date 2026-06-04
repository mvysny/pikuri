# frozen_string_literal: true

require 'open3'
require 'set'

module Pikuri
  # Chokepoint for *all* subprocess spawning in pikuri. Forces a new
  # process group for each invocation, tracks pgids so descendants of
  # the direct child (commands backgrounded with +&+) can be cleaned
  # up at process exit. Two front doors: {.spawn} (combined
  # stdout+stderr through a single pipe — the shell-command shape) and
  # {.run} (stdin fed, stdout redirected to a file, stderr captured —
  # the filter shape).
  #
  # == Seam discipline
  #
  # All subprocess spawning in +lib/+ goes through {.spawn}. Direct
  # +Process.spawn+ / +Open3.*+ / +system+ / backticks anywhere in
  # +lib/+ are bugs. The convention is grep-enforceable:
  # +grep -rnE 'Process\.spawn|Open3\.|\bsystem\(' lib/+ should
  # only hit this file (plus the comment in
  # +pikuri-mcp/lib/pikuri/mcp/servers.rb+ explaining the MCP
  # exception).
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
  # One +@active+ Set for the whole process, swept once at exit via
  # {Pikuri::Finalizers} (see the registration at the bottom of this
  # file). A +Mutex+ guards register/prune/cleanup; v1 is
  # single-threaded, so this is more for the exit-sweep/register race
  # than for current callers.
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

    # Run +argv+ as a one-shot *filter*: feed it +stdin_data+, redirect
    # its stdout straight to +stdout+ (an open +File+), capture stderr
    # through a pipe, and block until it exits. Built for the
    # stdin→markdown document converters (pikuri-extractors), where
    # {.spawn}'s shape is wrong twice over: it closes the child's stdin
    # immediately, and it merges stderr onto stdout — fatal when stdout
    # *is* the payload and a converter's warnings would corrupt it.
    #
    # Redirecting stdout to a file (not a pipe) is also what makes the
    # I/O deadlock-free with one writer thread: the child never blocks
    # writing output, so it keeps draining stdin, while the parent
    # drains the (low-volume) stderr pipe. The returned
    # {Result#output} is the captured *stderr* — the diagnostics — not
    # the payload; the payload is in +stdout+, whose file offset is
    # shared with the child, so rewind before reading it back.
    #
    # Same discipline as {.spawn}: new process group, registered for
    # the exit sweep, no built-in timeout (wrap +argv+ with coreutils'
    # +timeout+ — see the class docs).
    #
    # @param argv [Array<String>] command and arguments, passed to
    #   +exec+ directly — no implicit shell.
    # @param stdin_data [String] bytes written to the child's stdin,
    #   which is then closed (EOF). May be empty.
    # @param stdout [File] open writable file the child's stdout is
    #   redirected to.
    # @param chdir [String, Pathname] working directory.
    # @param env [Hash{String=>String}] extra environment variables,
    #   as for {.spawn}.
    # @return [Result] +output+ is the captured stderr; +status+ the
    #   child's exit status.
    def self.run(*argv, stdin_data:, stdout:, chdir:, env: {})
      in_r, in_w = IO.pipe
      err_r, err_w = IO.pipe
      pid = Process.spawn(env, *argv, chdir: chdir.to_s, pgroup: true,
                          in: in_r, out: stdout, err: err_w)
      in_r.close
      err_w.close
      register(pid)
      writer = Thread.new do
        in_w.binmode
        in_w.write(stdin_data)
      rescue Errno::EPIPE
        nil # child exited without draining stdin; its status tells the story
      ensure
        in_w.close
      end
      stderr = err_r.read
      err_r.close
      writer.join
      _, status = Process.waitpid2(pid)
      Result.new(output: stderr, status: status)
    ensure
      prune(pid) if pid
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

    # SIGTERM the whole process group without blocking for output —
    # the stop button for a *daemon* child (one the caller never
    # {#wait}s on, e.g. {Pikuri::Memory::Mem0Server}'s socat relay).
    # Best-effort and idempotent: an already-dead group is a no-op.
    # The group stays in the exit-sweep set until it actually dies,
    # so a child that ignores SIGTERM is still re-signalled by
    # {.cleanup!} at process exit.
    #
    # @return [void]
    def terminate
      Process.kill('-TERM', @pgid)
    rescue Errno::ESRCH
      # already gone
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

      # SIGTERM every tracked process group. Run at process exit via
      # {Pikuri::Finalizers} (production) and from +after+ blocks
      # (specs). Best-effort — ignores errors from already-dead groups.
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

# Registered at load (boot) — before any agent or server registers at
# construction time — so in {Pikuri::Finalizers}' LIFO sweep this runs
# LAST: graceful +#close+ on agents and servers first, then SIGTERM
# whatever child groups are still alive. The reaper, not a peer. (Was a
# standalone +at_exit+; routed through Finalizers so the order relative
# to every other teardown is controlled, not left to file load order.)
Pikuri::Finalizers.register { Pikuri::Subprocess.cleanup! }
