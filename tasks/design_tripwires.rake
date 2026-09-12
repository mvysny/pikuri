# Hooks the design/ doc-layer checks into rake (the layout is described in AGENTS.md, "Design docs").
# The bash script is the single implementation; this task only runs it.
#
# Install: copy to tasks/design_tripwires.rake and make sure the Rakefile loads it —
#   Dir.glob('tasks/*.rake').each { |r| load r }
# — then make it part of the umbrella check so CI runs it:
#   task check: %i[test design_tripwires]

desc 'Design docs: cited slugs resolve, AGENTS.md under 34 KB, CLAUDE.md is the shim'
task :design_tripwires do
  sh 'design/verify_design_tripwires.sh'
end
