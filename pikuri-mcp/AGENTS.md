# pikuri-mcp — AGENTS.md

This gem's must-not-break list, loaded beside the root `../AGENTS.md`
when work touches this directory. One-line invariants + pointers only, ≤ 10 KB;
the truth lives in the cited yardoc and `design/architecture.md`, roads not taken in
`../design/decisions.md`, the walk-through in `../book/mcp.md`.

## Seams (invariants)

- **MCP-tool bypass.** MCP tools synthesize as raw `RubyLLM::Tool` subclasses, not `Pikuri::Tool`s; the root's Display-line defaults are mechanical so they still render. See {Pikuri::Mcp::Servers}.
- **Subprocess-seam exception.** The stdio child is spawned *inside the third-party `mcp` gem*, one of the two sanctioned bypasses of `Pikuri::Subprocess.spawn` (root Subprocess seam); pikuri owns the teardown via `#close`. `T_subprocess_chokepoint` cannot see this one. See {Pikuri::Mcp::ClientWrapper}.
- **`StdioEntry#env` is the per-child credential channel**, merged over the de-bundlerized `Pikuri::BundlerEnv` base (root **Environment is not a secret store** seam). See {Pikuri::Mcp::Registry::StdioEntry}.
