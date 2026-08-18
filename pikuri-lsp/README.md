# pikuri-lsp

Language intelligence for a [pikuri](https://codeberg.org/mvysny/pikuri)
agent: the questions grep cannot answer — *where is this defined*, *who
calls it*, *what does it inherit from* — asked of a real language server
and relayed back verbatim.

**Read-only by construction.** No formatting, no code actions, no
diagnostics push, no rename, no workspace edits. The gem is named after
what it refuses to become: the moment it applies an edit it needs the
`Confirmer` seam and stops being a closeable, auditable piece.

> **Status: under construction.** The protocol layer, the client
> lifecycle and the configuration are in (the table below); the readiness
> gate and the `lsp` tool are not. Nothing is wired into an agent yet.

## What is here

| class | what it does |
| --- | --- |
| `Pikuri::Lsp::Connection` | JSON-RPC over one pair of IOs: framing, id demux on a reader thread, `null` replies to server-initiated requests, no timeout |
| `Pikuri::Lsp::Position` / `Range` | pikuri's 1-based line/character coordinates, converted to and from the wire's 0-based encoded offsets in exactly one place |
| `Pikuri::Lsp::PositionEncoding` | the `utf-8` / `utf-16` / `utf-32` offset arithmetic — mandatory, because jdtls ignores the `utf-8` offer |
| `Pikuri::Lsp::Location` | both wire shapes (`Location` and `LocationLink`) behind one value type |
| `Pikuri::Lsp::Uris` | `file:` URI ↔ path, and the scheme sniff that says "this result is not a file at all" |
| `Pikuri::Lsp::ServerProgress` | the domain event a host draws a progress bar from while a cold index runs |
| `Pikuri::Lsp::ClientWrapper` | one server's lifecycle: spawn, handshake, what it advertises, restart after a death, teardown |
| `Pikuri::Lsp::Registry` | which servers exist, which files each claims, and `.from_h` to build that from a host's own config file |
| `Pikuri::Lsp::Testing` | a scripted fake server and a hand-framed wire, so a host can test its integration with no language server installed (`require 'pikuri/lsp/testing'`) |

## Three rules it is built to

1. **Relay, don't work around.** Every language server is broken in its
   own way and the ways do not generalize, so the tool reports what the
   server said and the model decides what to do about it.
2. **Never collapse three answers into one.** *The server does not
   support this*, *the server answered nothing*, and *the server is not
   ready yet* stay three distinct strings. Merging them is how a shipped
   client teaches a model that a symbol has no definition when in fact
   the index was still building.
3. **No fallback steering.** An error says what failed. It never
   suggests grep.

## License

MIT, as the rest of pikuri.
