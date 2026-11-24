// The message each open compose window would send, as MIME text, built by
// Thunderbird's own MimeMessage into a temp file and deleted again: nothing
// is sent and no folder is written. The headers to check threading:
//   pikuri-thunderbird/dev/testbed/session js pikuri-thunderbird/dev/testbed/js/outgoing-mime.js
//   [ "Message-ID: <…@novak.example>\r\n…References: <noise-riders-0-0@inbox.example>\r\nIn-Reply-To: <noise-riders-0-0@inbox.example>\r\n…" ]
// The recipients, attachments, subject, identity and References are read as
// Send reads them; the body is always rendered text/plain, so a window
// composing HTML would send a different body part.
const resolve = arguments[arguments.length - 1];
(async () => {
  const { MimeMessage } = ChromeUtils.importESModule("resource:///modules/MimeMessage.sys.mjs");
  const out = [];
  for (const w of Services.wm.getEnumerator("msgcompose")) {
    const fields = Cc["@mozilla.org/messengercompose/composefields;1"].createInstance(Ci.nsIMsgCompFields);
    w.Recipients2CompFields(fields);
    w.Attachments2CompFields(fields);
    fields.subject = w.document.getElementById("msgSubject").value;
    fields.from = MailServices.headerParser.makeMimeAddress(w.gCurrentIdentity.fullName, w.gCurrentIdentity.email);
    fields.references = w.gMsgCompose.compFields.references;
    const body = w.GetCurrentEditor().outputToString("text/plain", 4);
    const message = new MimeMessage(w.gCurrentIdentity, fields, "", "text/plain", body,
                                    Ci.nsIMsgSend.nsMsgDeliverNow, "", w.gMsgCompose.type, [], null);
    const file = await message.createMessageFile();
    out.push(await IOUtils.readUTF8(file.path));
    await IOUtils.remove(file.path);
  }
  return out;
})().then(resolve, (e) => resolve({ error: String(e) }));
