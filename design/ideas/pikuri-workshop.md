# pikuri-workshop: leftovers from the split

Status: **the split is done** (2026-11-12): eight gems moved to
[pikuri-workshop](https://github.com/mvysny/pikuri-workshop), and the placement rule is
`D_gem_placement`. What's left is cleanup in pikuri that still names the moved gems.

- **`D_keep_calculator`** argues against `bash` beside the calculator, and lists the bins that
  wire it (`pikuri-code`, `pikuri-os`, `pikuri-memory`, `pikuri-openlibrary`…), most of which are
  now the workshop's. Rewrite it for a pikuri with no `bash`: the "pikuri can't assume the shell"
  arm gets stronger, the passive-command-detector arm is now the workshop's to argue.
- **Yardoc that names workshop symbols** (27 hits across core, pdf, workspace, subagents and
  vectordb: `{Pikuri::Code::Bash}`, `{Pikuri::Tasks::Extension}`, `{Pikuri::Mcp::Servers}`…)
  dangles on rubydoc.info; each wants a rewrite that names the seam, not the consumer.
  `grep -rnE "Pikuri::(Code|Tasks|Mcp|Lsp|Os|Skills|Memory|Extractors)::" pikuri-*/lib` finds
  them (the `Extractors::PDF` hits in `pikuri-pdf` are its own and fine).
