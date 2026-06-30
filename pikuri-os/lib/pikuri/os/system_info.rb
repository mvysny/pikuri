# frozen_string_literal: true

require 'etc'

module Pikuri
  module Os
    # Boot-time machine facts for the OS helper: the small block of facts
    # about *this* host that gets folded into the system prompt so the
    # model doesn't guess the distro, init system, or paths. See
    # +ideas/os-assistant.md+.
    #
    # == Mandatory info, optional source
    #
    # The core facts (distro, kernel, init, desktop, CPU/mem, home, shell,
    # date) are gathered from **always-present primitives** — Ruby's
    # +Etc+, +/etc/os-release+, +/proc+, and the environment — so the
    # block is deterministic, needs no external binary, and works on a
    # headless box or in CI. When +inxi+ is installed, its +inxi -b+
    # output is appended as extra hardware/desktop detail (machine type,
    # GPU, mobo, …); when it isn't, that section is simply omitted. inxi
    # is enrichment, never a dependency — a missing or failing +inxi+ is
    # never fatal.
    #
    # == Read-once-at-boot
    #
    # This is a snapshot taken when the prompt is first built; the date
    # in particular is "at startup". The host doesn't change distro
    # mid-session, so that's fine — and {#prompt_section} is **memoized**,
    # so the (subprocess-spawning) +inxi+ probe runs exactly once no
    # matter how often the prompt is re-assembled (e.g. on every
    # {Pikuri::Agent#clear_conversation}). Unlike {MachineMemory}, this
    # section deliberately does *not* refresh on clear.
    class SystemInfo
      # @return [Integer] cap on the appended +inxi -b+ block, so a chatty
      #   inxi can't bloat the prompt.
      INXI_MAX_BYTES = 4 * 1024

      # Ordered (fact-key, label) pairs for {.render}. A +nil+ value is
      # skipped, so a fact we couldn't read just doesn't appear.
      FACT_ORDER = [
        [:os,       'OS'],
        [:kernel,   'Kernel'],
        [:init,     'Init'],
        [:desktop,  'Desktop'],
        [:hostname, 'Hostname'],
        [:home,     'Home'],
        [:shell,    'Shell'],
        [:cpus,     'CPUs'],
        [:memory,   'Memory'],
        [:date,     'Date (at startup)']
      ].freeze

      # The system-prompt grounding section: a +# This machine+ heading,
      # the core facts, and (when +inxi+ is present) an extra-detail block.
      # Memoized — the +inxi+ subprocess runs only on the first call, so
      # re-pulling the prompt (every {Pikuri::Agent#clear_conversation}) is
      # free.
      #
      # @return [String]
      def prompt_section
        @prompt_section ||= begin
          parts = ['# This machine', '', self.class.render(facts)]
          detail = inxi_detail
          parts += ['', 'Further hardware/desktop detail (from `inxi -b`):', detail] if detail
          parts.join("\n")
        end
      end

      # Render a facts hash as +"- Label: value"+ lines in {FACT_ORDER},
      # skipping keys with no value. Pure — the testable core.
      #
      # @param facts [Hash{Symbol=>Object}]
      # @return [String]
      def self.render(facts)
        FACT_ORDER.filter_map do |key, label|
          value = facts[key]
          "- #{label}: #{value}" unless value.nil? || value.to_s.strip.empty?
        end.join("\n")
      end

      # The core facts, each gathered best-effort (a reader that fails
      # yields +nil+ and the line is dropped).
      #
      # @return [Hash{Symbol=>Object}]
      def facts
        {
          os:       os_pretty_name,
          kernel:   kernel_string,
          init:     init_system,
          desktop:  presence(ENV['XDG_CURRENT_DESKTOP']),
          hostname: uname[:nodename],
          home:     home_dir,
          shell:    presence(ENV['SHELL']),
          cpus:     cpu_count,
          memory:   total_memory,
          date:     Time.now.strftime('%Y-%m-%d %H:%M:%S %z')
        }
      end

      private

      # +inxi -b -c 0+ output (color stripped) when inxi is on PATH, capped
      # to {INXI_MAX_BYTES}; +nil+ when inxi is absent, errors, or is
      # empty. Never raises out — enrichment only.
      #
      # @return [String, nil]
      def inxi_detail
        result = Pikuri::Subprocess.spawn('inxi', '-b', '-c', '0', chdir: '/').wait
        return nil unless result.status.success?

        out = result.output.strip
        return nil if out.empty?

        out.bytesize > INXI_MAX_BYTES ? "#{out.byteslice(0, INXI_MAX_BYTES)}\n…" : out
      rescue Errno::ENOENT
        nil
      end

      # @return [String, nil] +PRETTY_NAME+ from +/etc/os-release+
      def os_pretty_name
        line = File.foreach('/etc/os-release').find { |l| l.start_with?('PRETTY_NAME=') }
        return nil unless line

        line.split('=', 2).last.strip.delete_prefix('"').delete_suffix('"')
      rescue SystemCallError
        nil
      end

      # @return [String, nil] +"<release> <machine>"+, e.g. "7.0.0-27-generic x86_64"
      def kernel_string
        u = uname
        return nil unless u[:release]

        [u[:release], u[:machine]].compact.join(' ')
      end

      # @return [Hash] memoized +Etc.uname+ (sysname/nodename/release/…),
      #   or +{}+ if unavailable.
      def uname
        @uname ||= (Etc.uname rescue {})
      end

      # @return [String, nil] PID 1's command (e.g. "systemd")
      def init_system
        presence(File.read('/proc/1/comm').strip)
      rescue SystemCallError
        nil
      end

      # @return [String, nil]
      def home_dir
        Dir.home
      rescue ArgumentError
        presence(ENV['HOME'])
      end

      # @return [Integer, nil]
      def cpu_count
        Etc.nprocessors
      rescue StandardError
        nil
      end

      # @return [String, nil] total RAM, e.g. "23.5 GiB", from /proc/meminfo
      def total_memory
        line = File.foreach('/proc/meminfo').find { |l| l.start_with?('MemTotal:') }
        return nil unless line

        kb = line[/(\d+)/, 1]&.to_i
        return nil unless kb

        format('%.1f GiB', kb / 1024.0 / 1024.0)
      rescue SystemCallError
        nil
      end

      # @return [String, nil] +value+ unless nil/blank
      def presence(value)
        value && !value.to_s.strip.empty? ? value : nil
      end
    end
  end
end
