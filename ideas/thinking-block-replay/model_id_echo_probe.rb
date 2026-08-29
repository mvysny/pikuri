# frozen_string_literal: true
#
# Does the backend echo back the model id pikuri asked for?
#
# `Agent#load_history!` compares a stored message's `model_id` (whatever the
# SERVER reported, `data['model']`) against `@chat.model&.id` (whatever pikuri
# REQUESTED, via Models.resolve). Those are two different namespaces. If they
# disagree, the thinking-block repair fires on every message of every load even
# with no model switch anywhere — silently turning "same-model keeps, cross-model
# drops" into "never keep".
#
# This runs one real turn and reports whether they match.
#
#   PIKURI_PROBE_BASE=http://localhost:8080/v1 \
#   PIKURI_PROBE_MODEL=qwen3-30b-a3b \
#   ruby model_id_echo_probe.rb
#
# Optional: PIKURI_PROBE_KEY (default 'not-needed'), PIKURI_PROBE_PROMPT.

require 'bundler/setup'
require 'pikuri-core'

BASE   = ENV['PIKURI_PROBE_BASE']  or abort 'set PIKURI_PROBE_BASE (e.g. http://localhost:8080/v1)'
MODEL  = ENV['PIKURI_PROBE_MODEL'] or abort 'set PIKURI_PROBE_MODEL (the id you put in your config)'
KEY    = ENV.fetch('PIKURI_PROBE_KEY', 'not-needed')
PROMPT = ENV.fetch('PIKURI_PROBE_PROMPT',
                   'Think briefly, then answer in one word: what is 17 * 23?')

transport = Pikuri::Agent::ChatTransport.from_openai_server(
  server: BASE, model: MODEL, api_key: KEY
)

agent = Pikuri::Agent.new(transport: transport, system_prompt: 'You are terse.')
agent.run_loop(user_message: PROMPT)

assistant = agent.export_history.messages.reverse.find { |m| m.role == 'assistant' }
abort 'no assistant message came back' unless assistant

requested = MODEL                 # what pikuri asked for  (== @chat.model&.id here)
reported  = assistant.model_id    # what the server said   (== data['model'])
match     = requested == reported

puts
puts "  requested (transport.model / @chat.model.id) : #{requested.inspect}"
puts "  reported  (message.model_id / data['model']) : #{reported.inspect}"
puts "  equal?                                       : #{match}"
puts

th = assistant.thinking
if th.nil?
  puts '  thinking: none returned — the repair has nothing to act on here either way.'
else
  puts "  thinking.text      : #{th.text ? "#{th.text.to_s[0, 60].inspect}…" : 'nil'}"
  puts "  thinking.signature : #{th.signature ? "present (#{th.signature.length} chars)" : 'nil'}"
end
puts

if match
  puts 'VERDICT: ids agree. The existing model_id comparison is sound on this'
  puts '         backend; the two-namespace issue is a hazard note, not a blocker.'
else
  puts 'VERDICT: ids DISAGREE. On this backend `keep` computes false for every'
  puts '         message on every load, with no switch involved — option 1 would'
  puts '         silently degenerate into option 6. Record the REQUESTED model id'
  puts '         on the message and compare that instead.'
end
agent.close
