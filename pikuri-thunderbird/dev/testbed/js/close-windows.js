// Closes every window but the main one — compose windows without a "save
// changes?" prompt, and the modal alert a failed hand-off leaves, which would
// otherwise block the next one. Windows stack, so run it between hand-offs.
//   pikuri-thunderbird/dev/testbed/session js pikuri-thunderbird/dev/testbed/js/close-windows.js
// Resolves with the number closed.
const resolve = arguments[arguments.length - 1];
(async () => {
  let closed = 0;
  for (const w of [...Services.wm.getEnumerator(null)]) {
    if (w.document.documentElement.getAttribute("windowtype") == "mail:3pane") {
      continue;
    }
    if (w.gMsgCompose) {
      w.gContentChanged = false;
      w.gMsgCompose.bodyModified = false;
    }
    w.close();
    closed++;
  }
  await new Promise((r) => setTimeout(r, 500));
  return closed;
})().then(resolve, (e) => resolve({ error: String(e) }));
