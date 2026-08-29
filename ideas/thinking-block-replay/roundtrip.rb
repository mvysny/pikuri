# frozen_string_literal: true
require 'bundler/setup'
require 'pikuri-core'
H = Pikuri::Agent::History

QWEN = 'unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M'

stored = H::Message.new(
  id: 'm1', role: 'assistant', model_id: QWEN, content: '391',
  thinking: H::Thinking.new(text: "Here's a thinking process: 17*23 = 391.", signature: nil)
)

def show(label, msg)
  t = msg.thinking
  puts format('  %-34s thinking=%s', label, t ? "text(#{t.text.length} chars)" : 'nil')
end

puts "SAME MODEL (no switch) — load then re-export"
keep = stored.thinking.nil? || stored.model_id.nil? || stored.model_id == QWEN
show('on disk before', stored)
in_chat = stored.to_ruby_llm(keep_signature: keep)
show("in @chat (keep=#{keep})", in_chat)
show('re-exported', H::Message.from_ruby_llm(in_chat, id: 'm1'))

puts "\nAFTER A SWITCH to grok-4.5 — load then re-export"
keep2 = stored.thinking.nil? || stored.model_id.nil? || stored.model_id == 'grok-4.5'
show('on disk before', stored)
today = stored.to_ruby_llm(keep_signature: keep2)
show("TODAY: in @chat (keep_sig=#{keep2})", today)
show('TODAY: re-exported', H::Message.from_ruby_llm(today, id: 'm1'))
opt1 = RubyLLM::Message.new(role: :assistant, content: today.content,
                            model_id: today.model_id, thinking: nil)
show('OPTION 1: in @chat', opt1)
show('OPTION 1: re-exported', H::Message.from_ruby_llm(opt1, id: 'm1'))
