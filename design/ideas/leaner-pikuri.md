# Leaner pikuri

What remains of the 2026-11-14/15 reachability audit (roots = the `bin/` scripts + every gem's
`lib/`). Its rules for what stays graduated into `D_read_what_you_run`; these are the side findings
still open.

- `Q_write_defaults` — promptless `Edit` and silent new-file `Write` are the defaults, yet only
  pikuri-code / tui-code use them; every pikuri root opts into confirm-all. Flip?
- `Q_global_ruby_llm_config` — three vectordb-using bins call `RubyLLM.configure` for the embedder;
  an unwritten exception to the Connection seam?
- `Q_stale_thunderbird_docs` — `MailCompose` yardoc ("never wired", flag `compose:` → is
  `allow_compose_mail:`); entry file's "v2"; `pikuri-computer:187` "five" tools (six).
