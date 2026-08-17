# frozen_string_literal: true

require 'json'

# The server side of an LSP channel, over in-process pipes.
#
# Frames bytes by hand on purpose: a parse bug the gem's own serializer agrees
# with would be invisible if both ends shared code (ideas/lsp/design.md
# §Testing). Drive it from the *example's* thread and put the client under test
# on a worker, or the pipe buffer will deadlock you.
#
#   channel, wire = LspWire.channel
#   connection = Pikuri::Lsp::Connection.new(**channel, server_id: 'test')
#   thread = Thread.new { connection.request('textDocument/hover') }
#   wire.reply(wire.take, 'contents' => 'hi')
#   thread.value   # => {"contents"=>"hi"}
class LspWire
  # @return [Array(Hash, LspWire)] the client's +{stdin:, stdout:}+ kwargs, and
  #   the server side of the same pair.
  def self.channel
    to_server = IO.pipe
    to_client = IO.pipe
    [{ stdin: to_server[1], stdout: to_client[0] },
     new(read: to_server[0], write: to_client[1])]
  end

  def initialize(read:, write:)
    @read = read
    @write = write
  end

  # @return [Hash] the next message the client wrote, blocking for it.
  def take
    headers = {}
    while (line = @read.readline("\r\n").chomp("\r\n")) != ''
      key, value = line.split(':', 2)
      headers[key.strip.downcase] = value.strip
    end
    JSON.parse(@read.read(Integer(headers.fetch('content-length'))))
  end

  def send_raw(body)
    @write.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
    @write.flush
  end

  def send_message(hash)
    send_raw(JSON.generate(hash))
  end

  def reply(request, result)
    send_message('jsonrpc' => '2.0', 'id' => request['id'], 'result' => result)
  end

  def reply_error(request, code:, message:)
    send_message('jsonrpc' => '2.0', 'id' => request['id'],
                 'error' => { 'code' => code, 'message' => message })
  end

  def notify(method, params = {})
    send_message('jsonrpc' => '2.0', 'method' => method, 'params' => params)
  end

  # Play the server half of the LSP handshake.
  #
  # @param capabilities [Hash] what to advertise back.
  # @param server_info [Hash, nil]
  # @return [Hash] the client's +initialize+ request, so an example can assert
  #   on what it declared.
  def handshake(capabilities: {}, server_info: nil)
    request = take
    raise "expected initialize, got #{request['method'].inspect}" unless request['method'] == 'initialize'

    result = { 'capabilities' => capabilities }
    result['serverInfo'] = server_info if server_info
    reply(request, result)
    initialized = take
    raise "expected initialized, got #{initialized['method'].inspect}" unless initialized['method'] == 'initialized'

    request
  end

  def close
    [@write, @read].each { |io| io.close unless io.closed? }
  end
end
