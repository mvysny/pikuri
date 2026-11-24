# frozen_string_literal: true

require 'fileutils'
require 'json'

module Pikuri
  module Demo
    # A Thunderbird running on the demo profile with Marionette on, so a
    # script can drive it: the builder's index step, and an agent's live test
    # (add an event, open a compose window, take a screenshot).
    #
    # Started detached, in its own process group, so it outlives the command
    # that started it; its pid and port are saved to a state file that later
    # commands attach to. Headless by default; with a display it runs on its
    # own Xvfb, whose screen {#screenshot} grabs.
    class Session
      # Resolves after asking Thunderbird to quit; a clean quit checkpoints
      # the WAL databases.
      QUIT_JS = <<~JS
        const resolve = arguments[arguments.length - 1];
        resolve(true);
        Services.tm.dispatchToMainThread(() => Services.startup.quit(Ci.nsIAppStartup.eAttemptQuit));
      JS

      # The virtual screen, for Xvfb and the screenshot.
      SCREEN = '1600x1000'

      # @return [Integer] Thunderbird's pid.
      attr_reader :pid

      # @return [Integer] Marionette's port.
      attr_reader :port

      # @return [String, nil] e.g. ":99", when on a display.
      attr_reader :display

      # Starts Thunderbird on +profile_dir+ and waits for Marionette.
      #
      # @param profile_dir [String]
      # @param log [String] Thunderbird's output.
      # @param display [Boolean] run on a fresh Xvfb instead of headless.
      # @return [Session]
      # @raise [RuntimeError] when Thunderbird doesn't come up.
      def self.start(profile_dir:, log:, display: false)
        port_file = File.join(profile_dir, 'MarionetteActivePort')
        FileUtils.rm_f(port_file)
        xvfb_pid, screen = display ? start_xvfb : [nil, nil]
        env = { 'MOZ_REMOTE_ALLOW_SYSTEM_ACCESS' => '1', 'MOZ_CRASHREPORTER_DISABLE' => '1' }
        env['DISPLAY'] = screen if screen
        # On a display it accepts remote commands, so a hand-off's plain
        # `thunderbird <arg>` (with that DISPLAY) opens in it, as on a desktop.
        mode = screen ? [] : ['--headless', '--no-remote']
        # setsid execs (no fork) when the child doesn't lead a process group,
        # so the pid stays Thunderbird's and the session survives this command.
        pid = Process.spawn(env, 'setsid', 'thunderbird', *mode, '--marionette', '-profile', profile_dir,
                            in: File::NULL, out: log, err: %i[child out])
        Process.detach(pid)
        session = new(pid: pid, port: nil, display: screen, xvfb_pid: xvfb_pid)
        session.wait_for_port(port_file, log)
        session
      rescue StandardError
        session&.kill || (Process.kill('TERM', xvfb_pid) if xvfb_pid)
        raise
      end

      # @param path [String] a state file {#save} wrote.
      # @return [Session, nil] the session, if it is still running.
      def self.load(path)
        return nil unless File.file?(path)

        state = JSON.parse(File.read(path))
        session = new(pid: state['pid'], port: state['port'], display: state['display'], xvfb_pid: state['xvfb_pid'])
        session.alive? ? session : nil
      end

      # @return [Array(Integer, String)] Xvfb's pid and its display.
      def self.start_xvfb
        number = (99..199).find { |n| !File.exist?("/tmp/.X11-unix/X#{n}") && !File.exist?("/tmp/.X#{n}-lock") }
        pid = Process.spawn('setsid', 'Xvfb', ":#{number}", '-screen', '0', "#{SCREEN}x24", '-nolisten', 'tcp',
                            in: File::NULL, out: File::NULL, err: File::NULL)
        Process.detach(pid)
        deadline = Time.now + 10
        sleep 0.1 until File.exist?("/tmp/.X11-unix/X#{number}") || Time.now > deadline
        raise "Xvfb :#{number} didn't come up" unless File.exist?("/tmp/.X11-unix/X#{number}")

        [pid, ":#{number}"]
      end
      private_class_method :start_xvfb

      # @param pid [Integer]
      # @param port [Integer, nil]
      # @param display [String, nil]
      # @param xvfb_pid [Integer, nil]
      def initialize(pid:, port:, display:, xvfb_pid:)
        @pid = pid
        @port = port
        @display = display
        @xvfb_pid = xvfb_pid
      end

      # @param port_file [String]
      # @param log [String]
      # @return [void]
      # @raise [RuntimeError] after 60 s, or when Thunderbird exits first.
      def wait_for_port(port_file, log)
        deadline = Time.now + 60
        until File.size?(port_file)
          raise "Thunderbird wrote no #{port_file} in 60s; see #{log}" if Time.now > deadline
          raise "Thunderbird exited early; see #{log}" unless alive?

          sleep 0.25
        end
        @port = Integer(File.read(port_file).strip)
      end

      # Runs a chrome-context script, in a Marionette session of its own.
      #
      # @param script [String] a function body; it resolves with
      #   +arguments[arguments.length - 1](value)+ (see {Marionette#execute_async}).
      # @param args [Array<String>] the script's +arguments+, before the callback.
      # @param timeout [Numeric] seconds.
      # @return [Object] the resolved value.
      def execute(script, args: [], timeout: 60)
        marionette = Marionette.connect(port: @port, wait: 10)
        marionette.execute_async(script, args: args, timeout: timeout)
      ensure
        marionette&.close
      end

      # @return [Boolean]
      def alive?
        Process.kill(0, @pid)
        true
      rescue Errno::ESRCH
        false
      end

      # Quits Thunderbird cleanly and stops its Xvfb.
      #
      # @param timeout [Numeric] seconds to wait for the exit.
      # @return [void]
      # @raise [RuntimeError] when it doesn't exit in time.
      def quit(timeout: 30)
        execute(QUIT_JS) if alive?
        deadline = Time.now + timeout
        sleep 0.25 while alive? && Time.now < deadline
        raise "Thunderbird (pid #{@pid}) didn't quit in #{timeout}s" if alive?
      ensure
        stop_xvfb
      end

      # SIGTERM to Thunderbird's process group, and its Xvfb. For when the
      # clean quit isn't an option.
      #
      # @return [void]
      def kill
        Process.kill('TERM', -@pid) if alive?
        stop_xvfb
      rescue Errno::ESRCH
        nil
      end

      # Grabs the Xvfb screen.
      #
      # @param path [String] a +.png+.
      # @return [void]
      # @raise [RuntimeError] for a headless session, or when ffmpeg fails.
      def screenshot(path)
        raise 'a headless session has no screen; start it with --display' unless @display

        ok = system('ffmpeg', '-loglevel', 'error', '-y', '-f', 'x11grab', '-video_size', SCREEN,
                    '-i', @display, '-frames:v', '1', path)
        raise "ffmpeg couldn't grab #{@display}" unless ok
      end

      # @param path [String]
      # @return [void]
      def save(path)
        File.write(path, JSON.generate(pid: @pid, port: @port, display: @display, xvfb_pid: @xvfb_pid))
      end

      private

      # @return [void]
      def stop_xvfb
        Process.kill('TERM', @xvfb_pid) if @xvfb_pid
      rescue Errno::ESRCH
        nil
      end
    end
  end
end
