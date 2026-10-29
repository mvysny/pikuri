# Emit `UserTurn` before the `/props` cap probe

Status: **diagnosed, fix sketched, not built.** Found from pikuri-web, where a
sent message showed up seconds late.

## The problem

`Agent#run_loop` (`pikuri-core/lib/pikuri/agent.rb`, ~line 379) runs
`detect_and_emit_context_cap!` *before* it appends and emits the user turn:

```ruby
drain_interloper if @interloper
...
detect_and_emit_context_cap! if @cap_pending        # blocking GET /props
unless blank
  track_message(@chat.add_message(role: :user, content: user_message))
  @listeners.emit(Event::UserTurn.new(content: user_message, mid_loop: false))
  dispatch_ext_on_user_message(user_message)
end
```

`@cap_pending` is true on the first turn after `Agent.new` and after a model
switch (`D_deferred_cap_probe`). Against a llama.cpp router,
`/props?model=<id>` answers only once the router has loaded that model, and
`ContextWindowDetector::READ_TIMEOUT` is deliberately generous. Until the
probe returns, no listener hears the user's message.

pikuri-tui never notices: `Listener::Terminal` stays silent on `UserTurn`
because the TUI echoes input locally. pikuri-web renders the user block *from*
`UserTurn` (server-authoritative transcript). There, the message appears only
once the model has loaded, at about the moment the first thinking frame
arrives. pikuri-web builds one agent per conversation, so this hits the first
message of every new conversation, the first message of any conversation after
a server restart, and the first message after a `/model` switch.

Reproduced with a fake llama server whose `/props` sleeps 3 s. With a fresh
agent, the user block arrived ~3.2 s after `POST /messages`, right behind the
completion request. On turn 2 of the same conversation it came at once.

## Proposed fix

Echo first, then probe, still ahead of extensions and the first request:

```ruby
unless blank
  track_message(@chat.add_message(role: :user, content: user_message))
  @listeners.emit(Event::UserTurn.new(content: user_message, mid_loop: false))
end
detect_and_emit_context_cap! if @cap_pending
dispatch_ext_on_user_message(user_message) unless blank
```

This keeps every constraint `D_deferred_cap_probe` names: after the
`EmptyTurnError` guard, after the cancellation reset, before the first request
(so `ServerPermits` is sized before `RequestThrottle` asks), and `ContextCap`
still before every `Tokens`. A blank turn has no `UserTurn` and still probes.
Drained interloper items already emit their `UserTurn(mid_loop: true)` ahead of
the probe, so nothing changes for them.

The model-load wait itself stays; the probe still blocks the turn. The only
change is that the user's message is on screen during the wait instead of after
it.

## To do

- Spec in `pikuri-core/spec/pikuri/agent_spec.rb`: with a probe that is
  observable (stubbed `ContextWindowDetector.detect` recording the time or order),
  `UserTurn` reaches a listener before `ContextCap` on a first turn, and
  `ContextCap` still precedes `Tokens`.
- Add a sentence to `design/decisions.md` `D_deferred_cap_probe` on why the
  probe sits after the user-turn emit (a host that renders `UserTurn` must not
  wait on a cold model load).

## Open questions

- `Q_ext_needs_cap`: does any extension's `on_user_message` (pikuri-memory's
  dispatch, a RAG injector) read the context cap? If so, keeping the probe
  ahead of `dispatch_ext_on_user_message`, as sketched, is required rather
  than incidental. Check before moving it any later.
- `Q_titler_permit`: in pikuri-web, a `[titler]` on the same server with
  `max_concurrent_requests = 1` starts its request beside the first turn and
  may take the only permit first. That delays the first *thinking*, not the
  echo, and was not verified. Likely a pikuri-web matter, noted here only so
  it isn't lost.
