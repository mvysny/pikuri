// The open compose windows, as Thunderbird parsed them: what a
// thunderbird_mail_compose hand-off put in front of the human.
//   pikuri-thunderbird/dev/testbed/session js pikuri-thunderbird/dev/testbed/js/compose-windows.js
// Resolves with [{type, from, to, cc, bcc, subject, references, attachments,
// body}]: type an nsIMsgCompType (0 new, 1 reply, 3 forward as attachment,
// 9 draft, 11 mailto), references the thread a reply joins, body as plain
// text.
const resolve = arguments[arguments.length - 1];
const windows = [];
for (const w of Services.wm.getEnumerator("msgcompose")) {
  const fields = Cc["@mozilla.org/messengercompose/composefields;1"].createInstance(Ci.nsIMsgCompFields);
  w.Recipients2CompFields(fields);
  windows.push({
    type: w.gMsgCompose.type,
    from: w.document.getElementById("msgIdentity").value,
    to: fields.to,
    cc: fields.cc,
    bcc: fields.bcc,
    subject: w.document.getElementById("msgSubject").value,
    references: w.gMsgCompose.compFields.references,
    attachments: [...w.gAttachmentBucket.itemChildren].map(({ attachment: a }) => ({
      name: a.name, url: a.url, size: a.size, contentType: a.contentType,
    })),
    body: w.GetCurrentEditor().outputToString("text/plain", 4),
  });
}
resolve(windows);
