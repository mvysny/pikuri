# frozen_string_literal: true

require 'json'
require 'socket'

module Pikuri
  module Demo
    # A minimal Marionette client: just enough of Mozilla's remote protocol to
    # run privileged JS inside a headless Thunderbird.
    #
    # The wire format is length-prefixed JSON over TCP: +len:payload+. The
    # server greets with +len:{hello}+; a command is +[0, id, "Name", params]+
    # and its reply +[1, id, error, result]+.
    #
    # The scripts run in *chrome context*, Mozilla's word for the
    # application's own privileged JS, so they can call Thunderbird's own APIs
    # (MailServices, Gloda). That needs +MOZ_REMOTE_ALLOW_SYSTEM_ACCESS=1+ in
    # Thunderbird's environment; on 159 the +--remote-allow-system-access+ flag
    # alone is not enough.
    class Marionette
      # Raised when the server answers a command with an error.
      class Error < StandardError; end

      # Connects, retrying until Thunderbird's listener is up.
      #
      # @param port [Integer]
      # @param wait [Numeric] seconds to keep retrying the connect.
      # @return [Marionette] a session already in chrome context.
      # @raise [Error] if nothing listens within +wait+.
      def self.connect(port:, wait: 60)
        deadline = Time.now + wait
        begin
          socket = TCPSocket.new('127.0.0.1', port)
        rescue Errno::ECONNREFUSED
          raise Error, "no Marionette on 127.0.0.1:#{port} after #{wait}s" if Time.now > deadline

          sleep 0.5
          retry
        end
        new(socket).tap(&:start_session)
      end

      # @param socket [TCPSocket]
      def initialize(socket)
        @socket = socket
        @next_id = 0
        read_packet # the hello
      end

      # Opens a WebDriver session and switches it to chrome context.
      #
      # @return [void]
      def start_session
        command('WebDriver:NewSession', {})
        command('Marionette:SetContext', { value: 'chrome' })
      end

      # Runs +script+ as an async function body; the script resolves by
      # calling +arguments[arguments.length - 1]+ with a JSON-able value.
      #
      # @param script [String]
      # @param timeout [Numeric] seconds before Marionette gives up on it.
      # @return [Object] the value the script resolved with.
      # @raise [Error] on a script error or a timeout.
      def execute_async(script, timeout: 60)
        result = command('WebDriver:ExecuteAsyncScript',
                         { script: script, args: [], scriptTimeout: (timeout * 1000).to_i })
        result['value']
      end

      # Ends the WebDriver session and disconnects. Marionette serves one
      # session at a time, so the next client can connect only after this.
      #
      # @return [void]
      def close
        return if @socket.closed?

        begin
          command('WebDriver:DeleteSession', {})
        rescue Error, IOError, SystemCallError
          nil # Thunderbird may already be quitting
        end
        @socket.close
      end

      private

      # @return [Hash] the command's result.
      # @raise [Error] if the server answered with an error.
      def command(name, params)
        id = (@next_id += 1)
        payload = JSON.generate([0, id, name, params])
        @socket.write("#{payload.bytesize}:#{payload}")
        loop do
          type, reply_id, error, result = read_packet
          next unless type == 1 && reply_id == id
          raise Error, "#{name}: #{error['error']}: #{error['message']}" if error

          return result
        end
      end

      # @return [Object] the decoded JSON of one packet.
      def read_packet
        length = +''
        while (char = @socket.read(1)) != ':'
          raise Error, 'Marionette closed the connection' if char.nil?

          length << char
        end
        JSON.parse(@socket.read(Integer(length)))
      end
    end
  end
end
