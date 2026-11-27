// The message each open compose window would send, as MIME text, built by
// Thunderbird's own MimeMessage into a temp file and deleted again: nothing
// is sent and no folder is written. The headers to check threading:
//   pikuri-thunderbird/dev/testbed/session js pikuri-thunderbird/dev/testbed/js/outgoing-mime.js
//   [ "Message-ID: <…@novak.example>\r\n…References: <noise-riders-0-0@inbox.example>\r\nIn-Reply-To: <noise-riders-0-0@inbox.example>\r\n…" ]
// The recipients, attachments, subject, identity and References are read as
// Send reads them, and so is the body: an HTML window's in its own send
// format (plain text, HTML or both), a plain-text window's through the
// plain-text serializer, each wrapped and format=flowed as Send does it.
// Both matched a real Send Later byte for byte (Thunderbird 161, 2026-11-27).
const resolve = arguments[arguments.length - 1];
(async () => {
  const { MimeMessage } = ChromeUtils.importESModule("resource:///modules/MimeMessage.sys.mjs");
  const { jsmime } = ChromeUtils.importESModule("resource:///modules/jsmime.sys.mjs");
  const out = [];
  for (const w of Services.wm.getEnumerator("msgcompose")) {
    const fields = Cc["@mozilla.org/messengercompose/composefields;1"].createInstance(Ci.nsIMsgCompFields);
    w.Recipients2CompFields(fields);
    w.Attachments2CompFields(fields);
    fields.subject = w.document.getElementById("msgSubject").value;
    fields.from = MailServices.headerParser.makeMimeAddress(w.gCurrentIdentity.fullName, w.gCurrentIdentity.email);
    fields.references = w.gMsgCompose.compFields.references;
    const editor = w.GetCurrentEditor();
    const E = Ci.nsIDocumentEncoder;
    let bodyType = "text/plain";
    // nsMsgCompose's own flags, which the plain-text Send runs in C++.
    let text = editor.outputToString("text/plain", E.OutputFormatted | E.OutputCRLineBreak | E.OutputLFLineBreak |
      (Services.prefs.getBoolPref("mailnews.send_plaintext_flowed", true) ? E.OutputFormatFlowed : 0));
    if (w.gMsgCompose.composeHTML) {
      // GenericSendMessage's send-format switch, then MessageSend#_getBodyFromEditor.
      const format = w.determineSendFormat();
      fields.forcePlainText = format == Ci.nsIMsgCompSendFormat.PlainText;
      fields.useMultipartAlternative = format == Ci.nsIMsgCompSendFormat.Both;
      bodyType = "text/html";
      text = editor.outputToString("text/html",
        E.OutputFormatted | E.OutputNoFormattingInPre | E.OutputDisallowLineBreaking);
      if (!fields.forcePlainText) {
        text = Cc["@mozilla.org/txttohtmlconv;1"].getService(Ci.mozITXTToHTMLConv)
          .scanHTML(text, Ci.mozITXTToHTMLConv.kURLs);
      }
    }
    // MimeMessage takes the body as UTF-8 bytes in a binary string; the
    // editor's UTF-16 text would go out as each code unit's low byte.
    const body = jsmime.mimeutils.typedArrayToString(new TextEncoder().encode(text));
    const message = new MimeMessage(w.gCurrentIdentity, fields, "", bodyType, body,
                                    Ci.nsIMsgSend.nsMsgDeliverNow, "", w.gMsgCompose.type, [], null);
    const file = await message.createMessageFile();
    out.push(await IOUtils.readUTF8(file.path));
    await IOUtils.remove(file.path);
  }
  return out;
})().then(resolve, (e) => resolve({ error: String(e) }));
