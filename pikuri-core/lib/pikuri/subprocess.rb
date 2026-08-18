# frozen_string_literal: true

require 'open3'
require 'set'

module Pikuri
  # Chokepoint for *all* subprocess spawning in pikuri. Forces a new process
  # group per invocation and tracks pgids so descendants (commands
  # backgrounded with +&+) can be cleaned up at exit. Two front doors:
  # {.spawn} (combined stdout+stderr through one pipe — the shell-command
  # shape) and {.run} (stdin from a String/IO, stdout to a file, stderr
  # captured — the filter shape).
  #
  # == Seam discipline
  #
  # All subprocess spawning in +lib/+ goes through {.spawn}/{.run}; direct
  # +Process.spawn+ / +Open3.*+ / +system+ / backticks are bugs.
  # Grep-enforceable: +grep -rnE 'Process\.spawn|Open3\.|\bsystem\(' lib/+
  # should hit only this file (plus the MCP-exception comment in
  # +pikuri-mcp/lib/pikuri/mcp/servers.rb+).
  #
  # == Timeouts are the caller's job
  #
  # {.spawn} implements no timeout — Ruby's +Timeout.timeout+ can't kill
  # subprocesses cleanly. Callers wrap their argv with coreutils' +timeout+:
  #
  #   Pikuri::Subprocess.spawn(
  #     'timeout', '--signal=TERM', '--kill-after=5s', '120s',
  #     'bash', '-c', command, chdir: workspace.cwd.to_s)
  #
  # When +timeout+ and its FD-inheriting children die, the output pipe closes
  # and {#wait}'s +io.read+ returns — +timeout+ handles the
  # SIGTERM-then-SIGKILL race-free, no Ruby-side machinery.
  #
  # == Backgrounded subprocesses
  #
  # A command that backgrounds work with +&+ leaves a process in our pgroup.
  # {#wait} returns when the direct child exits, but {.active} keeps the pgid
  # tracked while any group member is alive (+kill(0, -pgid)+); {.cleanup!}
  # SIGTERMs every tracked group at exit. The model opts out with +nohup+ /
  # +setsid+ (both detach from our group).
  #
  # == State is process-global
  #
  # One +@active+ Set for the process, swept once at exit via
  # {Pikuri::Finalizers}. A +Mutex+ guards register/prune/cleanup.
  class Subprocess
    # Combined output + exit status, returned from {#wait}.
    Result = Data.define(:output, :status)

    # Spawn +argv+ in a new process group with stderr on stdout. Tracked for
    # cleanup.
    #
    # @param argv [Array<String>] command + arguments, passed to +exec+
    #   directly — no implicit shell (caller wraps in +'bash', '-c', cmd+ when
    #   shell interpretation is wanted).
    # @param chdir [String, Pathname] working directory
    # @param env [Hash{String=>(String,nil)}] extra env vars for the child; it
    #   otherwise inherits the parent's full environment (default +{}+, pure
    #   inheritance). A +nil+ value *unsets* that variable, which is how
    #   {Pikuri::BundlerEnv} hands back the environment pikuri's own boot
    #   rewrote.
    # @return [Subprocess] handle — call {#wait} to block and read output.
    def self.spawn(*argv, chdir:, env: {})
      stdin, io, wait_thr = Open3.popen2e(env, *argv, chdir: chdir.to_s, pgroup: true)
      stdin.close
      register(wait_thr.pid)
      new(io: io, wait_thr: wait_thr)
    end

    # Run +argv+ as a one-shot *filter*: feed it +stdin_data+, redirect stdout
    # to +stdout+ (an open +File+), capture stderr through a pipe, block until
    # it exits. Built for the stdin→markdown converters (pikuri-extractors),
    # where {.spawn}'s shape is wrong twice: it closes stdin immediately and
    # merges stderr onto stdout — fatal when stdout *is* the payload.
    #
    # Redirecting stdout to a file (not a pipe) is what makes the I/O
    # deadlock-free with one writer thread: the child never blocks on output,
    # so it keeps draining stdin while the parent drains the low-volume stderr
    # pipe. {Result#output} is the captured *stderr*, not the payload — the
    # payload is in +stdout+, whose file offset is shared with the child, so
    # rewind before reading it back. Same discipline as {.spawn} (new group,
    # exit-sweep tracked, no built-in timeout).
    #
    # @param argv [Array<String>] command + arguments; no implicit shell.
    # @param stdin_data [String, IO, StringIO] the child's stdin: a String is
    #   written as-is, an IO is streamed via +IO.copy_stream+ from its current
    #   position (so a large file never hits the Ruby heap). Closed (EOF)
    #   after. May be empty.
    # @param stdout [File] open writable file stdout is redirected to.
    # @param chdir [String, Pathname] working directory.
    # @param env [Hash{String=>String}] extra env vars, as for {.spawn}.
    # @return [Result] +output+ is the captured stderr; +status+ the exit
    #   status.
    # @raise [SystemCallError] whatever an IO +stdin_data+ raises mid-stream,
    #   re-raised after the child is reaped.
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
        if stdin_data.respond_to?(:read)
          IO.copy_stream(stdin_data, in_w)
        else
          in_w.write(stdin_data)
        end
      rescue Errno::EPIPE
        nil # child exited without draining stdin; its status tells the story
      ensure
        in_w.close
      end
      stderr = err_r.read
      err_r.close
      # Reap before joining the writer: if an IO source raised
      # mid-stream, #join re-raises it, and the child (already exited —
      # err_r hit EOF) must not be left a zombie.
      _, status = Process.waitpid2(pid)
      writer.join
      Result.new(output: stderr, status: status)
    ensure
      prune(pid) if pid
    end

    # @return [Integer] direct child's pid
    attr_reader :pid

    # @return [Integer] process group id. Equal to {#pid} since the
    #   child was spawned with +pgroup: true+ (it's the group leader).
    attr_reader :pgid

    # @return [IO] read end of the combined stdout+stderr pipe. Callers
    #   normally go straight to {#wait}, which drains it.
    attr_reader :io

    # @api private — call {.spawn}, not the constructor.
    def initialize(io:, wait_thr:)
      @io       = io
      @wait_thr = wait_thr
      @pid      = wait_thr.pid
      @pgid     = wait_thr.pid # pgroup:true → pgid == pid
    end

    # Block until the direct child exits, drain the combined-output pipe,
    # return a {Result}. The pgid stays tracked if the group still has live
    # members (backgrounded children); pruned if everything's gone.
    #
    # @return [Result]
    def wait
      output = @io.read
      @io.close
      Result.new(output: output, status: @wait_thr.value)
    ensure
      self.class.send(:prune, @pgid)
    end

    # SIGTERM the whole process group without blocking for output — the stop
    # button for a *daemon* child (one the caller never {#wait}s on, e.g.
    # {Pikuri::Memory::Mem0Server}'s socat relay). Best-effort and idempotent;
    # the group stays in the exit-sweep set until it dies, so a child ignoring
    # SIGTERM is re-signalled by {.cleanup!} at exit.
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
      # Currently-tracked process groups, with dead ones pruned as a side
      # effect.
      #
      # @return [Array<Integer>]
      def active
        @mutex.synchronize do
          @active.delete_if { |g| !alive?(g) }
          @active.to_a
        end
      end

      # SIGTERM every tracked process group. Run at process exit via
      # {Pikuri::Finalizers}, and from specs' +after+ blocks. Best-effort.
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

# Registered at load (boot) — before any agent/server registers at
# construction — so in {Pikuri::Finalizers}' LIFO sweep this runs LAST:
# graceful +#close+ on agents and servers first, then SIGTERM whatever child
# groups remain. The reaper, not a peer.
Pikuri::Finalizers.register { Pikuri::Subprocess.cleanup! }
