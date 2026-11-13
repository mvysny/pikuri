// The open compose windows, as Thunderbird parsed them: what a
// thunderbird_mail_compose hand-off put in front of the human.
//   pikuri-thunderbird/dev/testbed/session js pikuri-thunderbird/dev/testbed/js/compose-windows.js
// Resolves with [{to, cc, bcc, subject, body}], body as plain text.
const resolve = arguments[arguments.length - 1];
const windows = [];
for (const w of Services.wm.getEnumerator("msgcompose")) {
  const fields = Cc["@mozilla.org/messengercompose/composefields;1"].createInstance(Ci.nsIMsgCompFields);
  w.Recipients2CompFields(fields);
  windows.push({
    to: fields.to,
    cc: fields.cc,
    bcc: fields.bcc,
    subject: w.document.getElementById("msgSubject").value,
    body: w.GetCurrentEditor().outputToString("text/plain", 4),
  });
}
resolve(windows);
