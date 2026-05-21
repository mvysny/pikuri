#!/usr/bin/env ruby
# frozen_string_literal: true

# Minimal in-tree MCP server used as the fixture for
# +spec/pikuri/mcp_servers_spec.rb+. Spawned over stdio by the
# +mcp+ gem's client so the integration specs exercise the real
# JSON-RPC framing, +tools/list+ / +tools/call+ round-trips, and
# subprocess lifecycle (close stdin → server exits on EOF).
#
# Tools exposed:
#
# * +echo+        — happy path; returns the +message+ argument as text.
# * +divide+      — recoverable failure path; returns +Error: division by zero+
#                   as MCP-side tool error when +b == 0+.
# * +slow+        — sleeps for the requested number of milliseconds before
#                   returning, used to exercise long-running tool calls.
# * +crash+       — calls +Process.exit(1)+ mid-call so specs can verify
#                   mid-conversation server death is surfaced as an
#                   +Error: ...+ observation rather than crashing the
#                   agent loop.

ENV['BUNDLE_GEMFILE'] ||= File.expand_path('../../Gemfile', __dir__)

require 'bundler/setup'
require 'mcp'

# Tool names are derived from the class name by MCP::Tool — +EchoTool+
# becomes the wire-side name +"echo_tool"+. To keep test assertions
# readable ("echo", "divide", ...), set +tool_name+ explicitly on each.

class EchoTool < MCP::Tool
  tool_name 'echo'
  description 'Echoes the given message back to the caller.'
  input_schema(
    properties: { message: { type: 'string' } },
    required: ['message']
  )

  def self.call(message:, server_context:)
    MCP::Tool::Response.new([{ type: 'text', text: message }])
  end
end

class DivideTool < MCP::Tool
  tool_name 'divide'
  description 'Divides a by b. Returns an MCP error when b == 0.'
  input_schema(
    properties: {
      a: { type: 'number' },
      b: { type: 'number' }
    },
    required: %w[a b]
  )

  def self.call(a:, b:, server_context:)
    if b.zero?
      MCP::Tool::Response.new(
        [{ type: 'text', text: 'division by zero' }],
        true # is_error
      )
    else
      MCP::Tool::Response.new([{ type: 'text', text: (a.to_f / b).to_s }])
    end
  end
end

class SlowTool < MCP::Tool
  tool_name 'slow'
  description 'Sleeps for `ms` milliseconds before returning ack.'
  input_schema(
    properties: { ms: { type: 'integer' } },
    required: ['ms']
  )

  def self.call(ms:, server_context:)
    sleep(ms / 1000.0)
    MCP::Tool::Response.new([{ type: 'text', text: 'ack' }])
  end
end

class CrashTool < MCP::Tool
  tool_name 'crash'
  description 'Exits the server process with status 1 mid-call.'
  # No-arg tool: JSON Schema rejects empty +required+ arrays, so we
  # declare neither +properties+ nor +required+. The MCP gem accepts
  # this shape (it just emits +{type: "object"}+).
  input_schema

  def self.call(server_context:)
    Process.exit(1)
  end
end

server = MCP::Server.new(
  name: 'pikuri-test-mcp',
  version: '0.0.1',
  tools: [EchoTool, DivideTool, SlowTool, CrashTool],
  instructions: 'In-tree fixture used by pikuri specs to exercise the MCP integration end-to-end.'
)

transport = MCP::Server::Transports::StdioTransport.new(server)
transport.open
