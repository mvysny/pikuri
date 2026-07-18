# frozen_string_literal: true

describe Pikuri::Thunderbird::IcalLine do
  IcalLine = Pikuri::Thunderbird::IcalLine

  it 'splits name, params and value, keeping the value colon' do
    l = IcalLine.parse('ATTENDEE;PARTSTAT=ACCEPTED;ROLE=REQ-PARTICIPANT:mailto:a@b.com')
    assert_equal 'ATTENDEE', l.name
    assert_equal 'ACCEPTED', l.params['PARTSTAT']
    assert_equal 'REQ-PARTICIPANT', l.params['ROLE']
    assert_equal 'mailto:a@b.com', l.value
  end

  it 'ignores a colon/semicolon inside a quoted param value' do
    l = IcalLine.parse('ATTENDEE;CN="Last, First: Jr;X";PARTSTAT=ACCEPTED:mailto:a@b.com')
    assert_equal 'Last, First: Jr;X', l.params['CN']
    assert_equal 'ACCEPTED', l.params['PARTSTAT']
    assert_equal 'mailto:a@b.com', l.value
  end

  it 'upcases param names and strips surrounding quotes' do
    l = IcalLine.parse('ORGANIZER;cn="Ann":mailto:ann@x.com')
    assert_equal 'ORGANIZER', l.name
    assert_equal 'Ann', l.params['CN']
  end

  it 'yields an empty value when the line has no unquoted colon' do
    l = IcalLine.parse('ATTENDEE;PARTSTAT=NEEDS-ACTION')
    assert_equal '', l.value
    assert_equal 'NEEDS-ACTION', l.params['PARTSTAT']
  end

  it 'skips a param token without an = sign' do
    l = IcalLine.parse('ATTENDEE;RSVP;PARTSTAT=DECLINED:mailto:a@b.com')
    refute l.params.key?('RSVP')
    assert_equal 'DECLINED', l.params['PARTSTAT']
  end

  describe '.attendee' do
    it 'builds an Attendee; email from the mailto value, name from CN' do
      a = IcalLine.attendee('ATTENDEE;CN="Vysny, Martin";PARTSTAT=ACCEPTED;ROLE=OPT-PARTICIPANT:mailto:m@x.com')
      assert_equal 'Vysny, Martin', a.name
      assert_equal 'm@x.com', a.email
      assert_equal 'ACCEPTED', a.status
      assert a.optional?
      refute a.organizer?
      refute a.resource?
    end

    it 'prefers the EMAIL param and flags the organizer' do
      a = IcalLine.attendee('ORGANIZER;CN=Ann;EMAIL=ann@x.com:mailto:other@x.com')
      assert a.organizer?
      assert_equal 'ann@x.com', a.email
    end

    it 'flags a resource and falls the name back to the email' do
      r = IcalLine.attendee('ATTENDEE;CUTYPE=RESOURCE:mailto:room@x.com')
      assert r.resource?
      assert_equal 'room@x.com', r.name
    end
  end
end
