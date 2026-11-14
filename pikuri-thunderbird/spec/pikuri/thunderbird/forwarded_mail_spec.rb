# frozen_string_literal: true

# The attachment list against what Gloda's attachmentInfos listed for the same
# trees at top level, measured on the testbed (Thunderbird 159): the Apple
# Mail, Outlook and odd-leaf shapes of dev/testbed/mail/*.eml, cut down.
describe Pikuri::Thunderbird::ForwardedMail do
  # @param tree [String] the forwarded mail's MIME entity, boundaries "A", "B", "C".
  # @return [String] the whole mail.
  def mail(tree) = "From: sami@example.com\nSubject: Quote\nMIME-Version: 1.0\n#{tree}".gsub("\n", "\r\n")

  # @return [Array<String>] the listed names.
  def listed(tree) = described_class.attachments(mail(tree)).map(&:name)

  it 'lists an Apple Mail attachment that sits inside the HTML alternative' do
    tree = <<~MIME
      Content-Type: multipart/alternative; boundary="A"

      --A
      Content-Type: text/plain

      the quote, as promised
      --A
      Content-Type: multipart/mixed; boundary="B"

      --B
      Content-Type: text/html

      <p>the quote, as promised</p>
      --B
      Content-Disposition: inline; filename=quote.pdf
      Content-Type: application/pdf; name="quote.pdf"

      %PDF-1.4
      --B
      Content-Type: text/html

      <p>Sami</p>
      --B--
      --A--
    MIME

    assert_equal ['quote.pdf'], listed(tree)
  end

  it "keeps Outlook's cid: signature image as body but lists an inline image under mixed" do
    tree = <<~MIME
      Content-Type: multipart/mixed; boundary="A"

      --A
      Content-Type: multipart/related; boundary="B"

      --B
      Content-Type: multipart/alternative; boundary="C"

      --C
      Content-Type: text/plain

      Claims Team
      --C
      Content-Type: text/html

      <img src="cid:image001.png@x">
      --C--
      --B
      Content-Type: image/png; name="image001.png"
      Content-Disposition: inline; filename="image001.png"
      Content-ID: <image001.png@x>

      png
      --B--
      --A
      Content-Type: application/pdf; name="claim-form.pdf"
      Content-Disposition: attachment; filename="claim-form.pdf"

      %PDF-1.4
      --A
      Content-Type: image/png; name="image002.png"
      Content-Disposition: inline; filename="image002.png"
      Content-ID: <image002.png@x>

      png
      --A
      Content-Type: application/ms-tnef; name="winmail.dat"
      Content-Disposition: attachment; filename="winmail.dat"

      tnef
      --A--
    MIME

    assert_equal %w[claim-form.pdf image002.png winmail.dat], listed(tree)
  end

  it "lists a nameless attachment as Gloda's Part path, and keeps an unnamed footer as body" do
    tree = <<~MIME
      Content-Type: multipart/mixed; boundary="A"

      --A
      Content-Type: text/plain

      your statement
      --A
      Content-Type: text/plain
      Content-Disposition: attachment

      account summary
      --A
      Content-Type: text/csv; name="statement.csv"

      invoice,total
      --A
      Content-Type: text/plain; name="notes.txt"
      Content-Disposition: inline; filename="notes.txt"

      no late fee
      --A
      Content-Type: application/octet-stream

      bytes
      --A
      Content-Type: text/plain

      Do not reply.
      --A--
    MIME

    assert_equal ['Part 1.2', 'statement.csv', 'notes.txt', 'Part 1.5'], listed(tree)
    out = described_class.render(mail(tree), handle: '3')
    assert_includes out, "Attachments:\n  3.1. Part 1.2 (text/plain, 15 B)\n  3.2. statement.csv (text/csv, 13 B)\n"
    assert_includes out, "your statement\n\nDo not reply."
    refute_includes out, 'account summary'
  end

  it "doesn't list an invitation's unnamed text/calendar alternative" do
    tree = <<~MIME
      Content-Type: multipart/alternative; boundary="A"

      --A
      Content-Type: text/plain

      two hours to plan the offsite
      --A
      Content-Type: text/calendar; method=REQUEST

      BEGIN:VCALENDAR
      END:VCALENDAR
      --A--
    MIME

    assert_empty listed(tree)
  end
end
