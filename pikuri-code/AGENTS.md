# pikuri-code — AGENTS.md

This gem's must-not-break list, loaded beside the root `../AGENTS.md`
when work touches this directory. One-line invariants + pointers only, ≤ 10 KB;
the truth lives in the cited yardoc, threat model + posture comparison in
`design/architecture.md`, roads not taken in `../design/decisions.md`.

## Seams (invariants)

- **Sandbox seam.** `Code::Bash` takes a `Code::Bash::Sandbox` (default `NONE`) and wraps every argv via `#wrap`; it governs the bash subprocess's fs view, where Workspace governs what the LLM observes. `FullFsNoNet` raises rather than degrading, and masks the live session's IPC sockets *after* the root bind (`D_headless_os_agent`). See {Pikuri::Code::Bash::Sandbox}.
- **Consumed seams.** `Bash` takes the bare `Workspace::Filesystem` (**Workspace seam**) and a `Workspace::Confirmer` (**Confirmer seam**), both owned by `../pikuri-workspace/AGENTS.md`; only Bash is sandboxed. Its child is spawned over `Pikuri::BundlerEnv.clean_delta` per the root's **Environment is not a secret store** seam. See {Pikuri::Code::Bash}.
