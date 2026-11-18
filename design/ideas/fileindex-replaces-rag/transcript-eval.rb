# frozen_string_literal: true

# Q_transcript_bar: does the secretary find things as well on the desktop file index as on rag?
# Ten lookup tasks over the demo home (~/Documents, dev/demo-home/build), each asked of a fresh
# agent, N runs per task per arm, arms interleaved so server state hits both alike.
#
#   DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus \
#     bundle exec ruby design/ideas/fileindex-replaces-rag/transcript-eval.rb OUT_DIR [RUNS] [ARMS] [TASKS]
#   bundle exec ruby design/ideas/fileindex-replaces-rag/transcript-eval.rb --summary OUT_DIR
#
# Both arms get the secretary's prompt and its non-retrieval document tools (calculator, the
# workspace's read/glob/list/write/edit over ~/Documents, writable Notes/, no grep), and differ
# only in retrieval:
#   rag       - Rag::Extension over an in-memory hybrid index of ~/Documents, bge-m3 + reranker,
#               a Watcher running, as bin/pikuri-secretary wires it minus Qdrant
#   fileindex - Fileindex::Extension, roots [~/Documents], over the VM's own localsearch index
# No mail and no web: both would answer some tasks around the retrieval under test.
#
# Resumable: a (task, arm, run) already in OUT_DIR/runs.jsonl is skipped.

require 'json'
require 'yaml'

ENV['BUNDLE_GEMFILE'] ||= File.expand_path('../../../Gemfile', __dir__)
require 'bundler/setup'
require 'pikuri-core'
require 'pikuri-pdf'
require 'pikuri-rag'
require 'pikuri-fileindex'
require 'pikuri-workspace'

REPO = File.expand_path('../../..', __dir__)
DOCUMENTS = File.expand_path('~/Documents')
NOTES = File.join(DOCUMENTS, 'Notes')
TIME_LIMIT = 300
NOTE_DELAY = 5 # seconds between saving the bike-lock note and asking: a human typing the next turn

# --- the tasks ---------------------------------------------------------------------------------
# gold: every regex must match the final answer. file: the document holding the answer.
TASKS = [
  { id: 'invoice', file: 'invoice-4471.pdf',
    q: 'How much do I owe Kettle & Co., and to which account do I pay it?',
    gold: [/1[,. ]?284[.,]50/, /FI21\s?1234\s?5600\s?0007\s?85/] },
  { id: 'notice', file: 'lease-agreement.pdf',
    q: 'If I want to move out of my flat, how much notice do I have to give?',
    gold: [/\b(one|1)\b[^.\n]{0,25}month/i] },
  { id: 'flood', file: 'home-insurance-policy.pdf',
    q: 'My kitchen got flooded. How much would I pay myself on an insurance claim, and how soon do I have to report it?',
    gold: [/\b450\b/, /\b14\b[^.\n]{0,5}days|fourteen days/i] },
  { id: 'sauna', file: 'sauna-stove-guide.html',
    q: 'How powerful a stove do I need for a 10 cubic metre sauna?',
    gold: [/\b9\s*kW/i] },
  { id: 'solar', file: 'house.md',
    q: 'Who installed the solar panels at the cottage, and what inverter do we have?',
    gold: [/P[äa]iv[äa]paiste/i, /Fronius/i] },
  { id: 'office', file: 'meeting-notes-board.pdf',
    q: 'Where is the office moving, and when?',
    gold: [/Tampere/, /March\s*(of\s*)?2027|2027-03/i] },
  { id: 'electricity', file: 'budget.csv',
    q: 'How much did I spend on electricity in October?',
    gold: [/\b131\b/] },
  { id: 'dentist', file: 'dentist.md',
    q: "When's my next dental appointment?",
    gold: [/(December|Dec)\.?\s*4\b|\b4(th)?\s*(of\s*)?Dec|2026-12-04|\b4\.12\./i, /\b8[:.]30\b|08[:.]30/] },
  { id: 'finnish-rent', file: 'lease-agreement.pdf',
    q: 'Paljonko kuukausivuokrani on, ja mihin päivään mennessä se pitää maksaa?',
    gold: [/1[  ,.]?150/, /\b5(\.|th)|fifth|viide/i] },
  { id: 'bike-lock', file: 'bike-lock.md',
    q: "What's the code for my bike lock?",
    gold: [] } # the code is drawn per run, see setup
].freeze

def setup_task(task)
  return {} unless task[:id] == 'bike-lock'

  code = format('%04d', rand(10_000))
  File.write(File.join(NOTES, 'bike-lock.md'), "# Bike lock\n\nThe code for the blue bike's lock is #{code}.\n")
  sleep NOTE_DELAY
  { gold: [/\b#{code}\b/], code: code }
end

# --- the arms -----------------------------------------------------------------------------------
def build_arms(names)
  config = YAML.safe_load_file(File.expand_path('~/.pikuri-examples-config.yaml'))
  server = config.fetch('llm_server')
  api_key = config.fetch('llm_api_key', 'not-needed')
  arms = { transport: Pikuri::Agent::ChatTransport.from_openai_server(server: server, model: config.fetch('llm_model'),
                                                                      api_key: api_key) }
  if names.include?('rag')
    embedder = Pikuri::VectorDb::Embedder.new(server: server, model: config.fetch('embed_model'), api_key: api_key)
    reranker = Pikuri::VectorDb::Reranker::LlamaServer.new(server: config['reranker_server'] || server,
                                                           model: config.fetch('reranker_model'), api_key: api_key)
    vectors = Pikuri::VectorDb::Server::InMemory.ensure_running
    corpus = Pikuri::VectorDb::Corpus.new(
      backend: Pikuri::Rag::Backend::Hybrid.new(vectors: vectors.client(collection: 'transcript-eval'),
                                                keywords: Pikuri::Rag::Backend::Fts5.new),
      source: DOCUMENTS, embedder: embedder, private: true, trusted: false
    )
    started = Time.now
    warn "rag: indexed #{corpus.index_all!} chunks in #{(Time.now - started).round}s"
    arms[:watcher] = Pikuri::VectorDb::Watcher.new(corpus: corpus).start
    arms['rag'] = -> { Pikuri::Rag::Extension.new(corpus: corpus, reranker: reranker) }
  end
  if names.include?('fileindex')
    roots = Pikuri::Fileindex::Roots.new(dirs: [DOCUMENTS], private: true)
    backend = Pikuri::Fileindex.pick(roots)
    warn "fileindex: #{backend.label}"
    arms['fileindex'] = -> { Pikuri::Fileindex::Extension.new(roots: roots, backend: backend) }
  end
  arms
end

def system_prompt
  Pikuri.prompts(:'pikuri-secretary', :'agent-loop') +
    "\n\nNotes/SECRETARY.md does not exist yet or is empty; create it the first time the user asks you to " \
    'remember something.' \
    "\n\nToday is #{Time.now.strftime('%A, %Y-%m-%d')}.\nDocuments folder: #{DOCUMENTS}\nNotes folder: #{NOTES}"
end

# --- one run ------------------------------------------------------------------------------------
class Recorder < Pikuri::Agent::Listener::Base
  attr_reader :calls, :results, :answers, :tokens

  def initialize
    @calls = []
    @results = []
    @answers = []
    @tokens = { 'input' => 0, 'output' => 0 }
  end

  def on_event(event)
    case event
    in Pikuri::Agent::Event::ToolCall(name:, arguments:)
      @calls << { 'name' => name, 'args' => arguments }
    in Pikuri::Agent::Event::ToolResult(name:, content:, summary:)
      @results << { 'name' => name, 'summary' => summary, 'content' => content.to_s[0, 2000] }
    in Pikuri::Agent::Event::Assistant(content:)
      @answers << content
    in Pikuri::Agent::Event::Tokens(input:, output:)
      @tokens['input'] += input.to_i
      @tokens['output'] += output.to_i
    else
      nil
    end
  end
end

def notes_snapshot = Dir.glob(File.join(NOTES, '**', '*')).select { File.file?(_1) }.to_h { [_1, File.binread(_1)] }

# Undo whatever a run wrote into Notes/, so the next run sees the demo home as built.
def restore_notes(snapshot)
  now = notes_snapshot
  changed = now.keys.reject { |path| snapshot[path] == now[path] }
  (now.keys - snapshot.keys).each { File.delete(_1) }
  snapshot.each { |path, bytes| File.binwrite(path, bytes) unless now[path] == bytes }
  changed
end

def run_one(task, arm, run, arms)
  snapshot = notes_snapshot
  extra = setup_task(task)
  gold = extra[:gold] || task[:gold]
  recorder = Recorder.new
  cancellable = Pikuri::Agent::Control::Cancellable.new
  agent = Pikuri::Agent.new(transport: arms[:transport], system_prompt: system_prompt, cancellable: cancellable) do |c|
    c.add_listener recorder
    c.add_tool Pikuri::Tool::CALCULATOR
    c.add_extension arms.fetch(arm).call
    c.add_extension Pikuri::Workspace::Extension.new(
      filesystem: Pikuri::Workspace::Filesystem.new(project_root: DOCUMENTS, root_writable: false, writable: [NOTES],
                                                    private: true, trusted: false),
      confirmer: Pikuri::Workspace::Confirmer::AUTO_APPROVE, grep: false
    )
  end
  started = Time.now
  timer = Thread.new { sleep TIME_LIMIT; cancellable.cancel! }
  error = nil
  begin
    agent.run_loop(user_message: task[:q])
  rescue Pikuri::Agent::Control::Cancellable::Cancelled
    error = 'timeout'
  rescue StandardError => e
    error = "#{e.class}: #{e.message[0, 300]}"
  ensure
    timer.kill
    agent.close
  end
  seconds = (Time.now - started).round(1)
  written = restore_notes(snapshot) - [File.join(NOTES, 'bike-lock.md')]
  answer = recorder.answers.last.to_s
  { 'task' => task[:id], 'arm' => arm, 'run' => run, 'pass' => error.nil? && gold.all? { answer.match?(_1) },
    'found' => recorder.results.any? { _1['content'].include?(task[:file]) },
    'code' => extra[:code], 'calls' => recorder.calls.size,
    'tools' => recorder.calls.map { _1['name'] }.tally, 'seconds' => seconds, 'tokens' => recorder.tokens,
    'error' => error, 'written' => written, 'tool_calls' => recorder.calls, 'tool_results' => recorder.results,
    'answer' => answer }
end

# --- summary ------------------------------------------------------------------------------------
def summary(out_dir)
  rows = File.readlines(File.join(out_dir, 'runs.jsonl')).map { JSON.parse(_1) }
  arms = rows.map { _1['arm'] }.uniq.sort
  puts format('%-13s %s', 'task', arms.map { format('%-28s', "#{_1} pass/found/calls/s") }.join)
  rows.map { _1['task'] }.uniq.each do |task|
    cells = arms.map do |arm|
      rs = rows.select { _1['task'] == task && _1['arm'] == arm }
      next format('%-28s', '-') if rs.empty?

      format('%-28s', format('%2d/%-2d %2d  %4.1f %5.0f', rs.count { _1['pass'] }, rs.size, rs.count { _1['found'] },
                             rs.sum { _1['calls'] }.fdiv(rs.size), rs.sum { _1['seconds'] }.fdiv(rs.size)))
    end
    puts format('%-13s %s', task, cells.join)
  end
  arms.each do |arm|
    rs = rows.select { _1['arm'] == arm }
    puts format('%-10s pass %3d/%-3d (%.0f%%)  found %3d  errors %d  mean %.0fs  tools %s', arm, rs.count { _1['pass'] },
                rs.size, 100.0 * rs.count { _1['pass'] } / rs.size, rs.count { _1['found'] },
                rs.count { _1['error'] }, rs.sum { _1['seconds'] } / rs.size,
                rs.flat_map { _1['tools'].flat_map { |k, v| [k] * v } }.tally.sort_by { -_2 }.to_h)
  end
end

if ARGV[0] == '--summary'
  summary(ARGV.fetch(1))
  exit
end

Pikuri::PROMPT_DIRS << File.join(REPO, 'prompts')
Pikuri::Extractors::PDF.register

out_dir = ARGV[0] or abort 'usage: transcript-eval.rb OUT_DIR [RUNS] [ARMS] [TASKS] | --summary OUT_DIR'
runs = (ARGV[1] || 10).to_i
arm_names = (ARGV[2] || 'rag,fileindex').split(',')
tasks = ARGV[3] ? TASKS.select { ARGV[3].split(',').include?(_1[:id]) } : TASKS
Dir.mkdir(out_dir) unless Dir.exist?(out_dir)
path = File.join(out_dir, 'runs.jsonl')
done = File.exist?(path) ? File.readlines(path).map { JSON.parse(_1).values_at('task', 'arm', 'run') } : []

arms = build_arms(arm_names)
begin
  (1..runs).each do |run|
    tasks.each do |task|
      arm_names.each do |arm|
        next if done.include?([task[:id], arm, run])

        row = run_one(task, arm, run, arms)
        File.open(path, 'a') { _1.puts(JSON.generate(row)) }
        warn format('run %2d %-12s %-9s pass=%-5s found=%-5s calls=%2d %5.0fs %s%s', run, task[:id], arm, row['pass'],
                    row['found'], row['calls'], row['seconds'], row['error'] || '',
                    row['written'].empty? ? '' : " wrote #{row['written'].map { File.basename(_1) }.join(',')}")
      end
    end
  end
ensure
  arms[:watcher]&.close
end
