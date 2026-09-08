# pikuri-lsp — CLAUDE.md

This gem's must-not-break list, loaded beside the root `../CLAUDE.md`
when work touches this directory. One-line invariants + pointers only;
the truth lives in the cited yardoc, threat model + measurements in
`DESIGN.md`, roads not taken in `../DECISIONS.md`'s `D_lsp_*` entries,
the walk-through in `book/lsp.md`.

## Seams (invariants)

- **LSP seam.** A language server is a *foreign binary reading the project*, so: **one root, never configurable** (`StdioEntry` has no `root:` / `cwd:`); **every result is a walked path** through `Filesystem#denied?`, `hover` prose included (`D_lsp_hover_file_uris`); **pikuri reads `file:` paths and nothing else**, a new scheme being a protocol decision, not config (`D_lsp_scheme_fallback`); servers start on **first use**; every `didOpen` is balanced by a `didClose` per call (`D_lsp_document_sync`). `T_lsp_denied_sites`, `T_lsp_finding_ids` (the `F_` / `J_` / `H_` / `S_` findings in `DESIGN.md` §Measurements). See {Pikuri::Lsp::Sources}, {Pikuri::Lsp::Servers}, {Pikuri::Lsp::Registry::StdioEntry}.
- **Subprocess-seam exception.** `Lsp::ClientWrapper`'s own `Open3.popen3` is one of the two sanctioned bypasses of `Pikuri::Subprocess.spawn` (root Subprocess seam): a long-lived stdio child that owns its teardown (`#close`, `pgroup: true` + SIGTERM to the group). See {Pikuri::Lsp::ClientWrapper}.
- **Consumed seams.** `Lsp::Sources` / `Lsp::Renderer` are on the **Denylist seam** roster in `../pikuri-workspace/CLAUDE.md`, which owns the rule.
