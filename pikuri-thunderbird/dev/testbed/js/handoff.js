// A hand-off without a display: the command line goes to Thunderbird's own
// handler, the one a remoted `thunderbird …` reaches, and the script waits for
// what it opens. Pass absolute paths.
//   pikuri-thunderbird/dev/testbed/session js pikuri-thunderbird/dev/testbed/js/handoff.js 'mailto:juha.salo@inbox.example?In-Reply-To=%3Cnoise-riders-0-0%40inbox.example%3E&body=Count%20me%20in.'
//   pikuri-thunderbird/dev/testbed/session js pikuri-thunderbird/dev/testbed/js/handoff.js -compose "type=3,originalMsgURI='imap-message://alex%40novak.example@127.0.0.1/INBOX#3',to=petr@example.org"
//   pikuri-thunderbird/dev/testbed/session js pikuri-thunderbird/dev/testbed/js/handoff.js ~/snap/thunderbird/common/pikuri-outbox/reply.eml
// Resolves with [{type, title, text}], one per window it opened: a compose
// window (text = its plain-text body) or an alert over one (a missing
// message= or attachment= file). Read a compose window in full with
// compose-windows.js, and close them all with close-windows.js before the
// next hand-off.
//
// A bare null means Marionette met an alert over the main window (a missing
// .eml) and dismissed it itself; the next `session js` then fails once with
// "unexpected alert open".
//
// Not covered: pikuri's own `setsid thunderbird …` launch remoting into the
// instance, which takes a --display session.
const resolve = arguments[arguments.length - 1];
const argv = [...arguments].slice(0, -1);
(async () => {
  const { MessengerContentHandler } = ChromeUtils.importESModule(
    "resource:///modules/MessengerContentHandler.sys.mjs"
  );
  const before = new Set(Services.wm.getEnumerator(null));
  const opened = () => [...Services.wm.getEnumerator(null)].filter((w) => !before.has(w));
  const describe = (w) => {
    const type = w.document.documentElement.getAttribute("windowtype") || "dialog";
    let text;
    if (type == "msgcompose") {
      text = w.GetCurrentEditor?.()?.outputToString("text/plain", 4) ?? null;
    } else {
      const node = w.document.getElementById("infoBody") || w.document.documentElement;
      text = node.textContent.replace(/\s+/g, " ").trim().slice(0, 300);
    }
    return { type, title: w.document.title, text };
  };

  // Dispatched, not called: a missing .eml raises its alert inside handle(),
  // and a modal alert would hold this script until Marionette's timeout.
  Services.tm.dispatchToMainThread(() =>
    new MessengerContentHandler().handle(
      Cu.createCommandLine(argv, null, Ci.nsICommandLine.STATE_REMOTE_EXPLICIT)
    )
  );
  // A reply's quote lands a while after its window opens: done once the new
  // windows have read the same for a second.
  let last = null;
  let same = 0;
  for (let i = 0; i < 60 && same < 4; i++) {
    await new Promise((r) => setTimeout(r, 250));
    const now = JSON.stringify(opened().map(describe));
    same = now == last && opened().length ? same + 1 : 0;
    last = now;
  }
  return opened().map(describe);
})().then(resolve, (e) => resolve({ error: String(e) }));
