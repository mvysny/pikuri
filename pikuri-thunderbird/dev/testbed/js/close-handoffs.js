// Closes what the hand-offs opened, unsaved and unasked: every compose window,
// and every tab but the first (an .ics hand-off's import wizard opens as a tab).
// For runs that hand off many times in one session, between one and the next.
//   pikuri-thunderbird/dev/testbed/session js pikuri-thunderbird/dev/testbed/js/close-handoffs.js
// Resolves with {compose, tabs}: how many of each it closed, once they're gone.
const resolve = arguments[arguments.length - 1];
const composers = [...Services.wm.getEnumerator("msgcompose")];
for (const w of composers) {
  // The compose window asks to save a changed draft; these say nothing changed.
  w.gContentChanged = false;
  if (w.gMsgCompose) w.gMsgCompose.bodyModified = false;
  w.ComposeCanClose = () => true;
  w.close();
}
let tabs = 0;
const main = Services.wm.getMostRecentWindow("mail:3pane");
const tabmail = main && main.document.getElementById("tabmail");
if (tabmail) {
  for (const tab of [...tabmail.tabInfo].slice(1).reverse()) {
    tabmail.closeTab(tab);
    tabs++;
  }
}
const deadline = Date.now() + 10000;
(function wait() {
  const left = [...Services.wm.getEnumerator("msgcompose")].length;
  if (left === 0 || Date.now() > deadline) resolve({ compose: composers.length - left, tabs });
  else setTimeout(wait, 100);
})();
