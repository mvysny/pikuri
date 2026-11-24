// Double-clicks an attachment chip in the open compose window, as the human
// reviewing a hand-off would, and reads back what opens: for a forwarded
// mail (`-compose type=3`), a message window on the very copy Send emits.
//   pikuri-thunderbird/dev/testbed/session js pikuri-thunderbird/dev/testbed/js/open-attachment.js [INDEX]
// INDEX is the chip's position, 0 (the first) by default. Resolves with
// [{windowtype, title, uri, attachments: [{name, contentType, url}], body}],
// one per window that opened; body is the shown message's text, cut at 300
// characters. Close them with close-windows.js before the next hand-off.
//
// Trusted clicks only: the chip's dblclick listener is chrome code, which
// ignores a constructed MouseEvent, so nothing opens and nothing errs. Hence
// Window.synthesizeMouseEvent, as Mozilla's EventUtils does;
// windowUtils.sendMouseEvent is gone in Thunderbird 160.
const resolve = arguments[arguments.length - 1];
const index = Number(arguments.length > 1 ? arguments[0] : 0);
(async () => {
  const compose = [...Services.wm.getEnumerator("msgcompose")][0];
  if (!compose) {
    return { error: "no compose window open" };
  }
  const item = compose.gAttachmentBucket.itemChildren[index];
  if (!item) {
    return { error: `no attachment chip at ${index}` };
  }
  item.scrollIntoView();
  const rect = item.getBoundingClientRect();
  const x = rect.left + rect.width / 2;
  const y = rect.top + rect.height / 2;
  const before = new Set(Services.wm.getEnumerator(null));
  for (const clickCount of [1, 2]) {
    for (const type of ["mousedown", "mouseup"]) {
      compose.synthesizeMouseEvent(type, x, y, { button: 0, clickCount }, { isDOMEventSynthesized: true });
    }
  }

  const opened = () => [...Services.wm.getEnumerator(null)].filter((w) => !before.has(w));
  const messageOf = (w) => w.document.getElementById("messageBrowser")?.contentWindow;
  for (let i = 0; i < 40 && !opened().some((w) => messageOf(w)?.gMessage); i++) {
    await new Promise((r) => setTimeout(r, 250));
  }
  return opened().map((w) => {
    const about = messageOf(w);
    const body = about?.document.getElementById("messagepane")?.contentDocument?.body;
    return {
      windowtype: w.document.documentElement.getAttribute("windowtype") || "dialog",
      title: w.document.title,
      uri: about?.gMessageURI ?? null,
      attachments: (about?.currentAttachments ?? []).map((a) => ({
        name: a.name, contentType: a.contentType, url: a.url,
      })),
      body: body?.textContent.replace(/\s+/g, " ").trim().slice(0, 300) ?? null,
    };
  });
})().then(resolve, (e) => resolve({ error: String(e) }));
