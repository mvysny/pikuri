# frozen_string_literal: true

require 'sqlite3'

module Pikuri
  module Thunderbird
    # The mechanical outbound guard for {MailCompose} — deterministic, never an
    # AI verdict. The compose window is a strong human barrier on the *visible*
    # (the recipient, gross body content) but soft on the *invisible* (control
    # bytes, look-alike domains, subtle body-exfil), so the machine covers what
    # the eye can't. It runs *before* {MailtoUri} encodes anything.
    #
    #   ComposeGuard.new(backend: contacts).check(to: 'a@acme.com', body: 'Hi')
    #   # => #<Verdict ok=true, to=["a@acme.com"], notes=[...]>
    #
    # Two tiers:
    #
    # * *Hard reject* — a suspicious **body** fails closed (nothing is handed
    #   off; the human retypes in Thunderbird), because an agent-authored
    #   outbound body has no honest reason to carry control/bidi/zero-width/
    #   homoglyph characters. A suspicious **subject or address** is dropped
    #   (omitted from the draft) for the human to retype — addresses additionally
    #   must be ASCII-only and non-punycode (an +xn--+ domain is a pre-encoded
    #   homoglyph that would otherwise pass {Pikuri::Sanitizer}'s mixed-script
    #   check as pure ASCII).
    # * *Soft warn* — the novelty check: a recipient domain the user has never
    #   sent mail to (per {Gloda::Contacts#domains_sent_to}) stays in the draft
    #   but earns a loud note urging out-of-band verification. A
    #   hard reject here would fire on every genuinely-new correspondent. A body
    #   carrying an *encoded-looking blob* (a long base64, hex or base32 run —
    #   see {#body_blob_note}) likewise stays but earns a located note.
    #
    # == Why per-field address omission
    #
    # If any address in a field (To/Cc/Bcc) fails the hard checks, the *whole*
    # field is dropped, not just the bad address — "the recipient is the attack,"
    # so forcing a full retype of a tainted field beats silently keeping the
    # addresses that happened to pass beside it.
    #
    # Immutable.
    class ComposeGuard
      LOGGER = Pikuri.logger_for('Thunderbird::ComposeGuard')

      # Shortest token the blob spotter sums toward a body warning. Below 16 the
      # three-class test gets flaky and honest engineering tokens (short SHAs,
      # build IDs) creep in — and since the sum is body-wide, that means alarm
      # fatigue. See {#body_blob_note}.
      BLOB_TOKEN_MIN = 16

      # Joined blob-token length at/above which the body earns the encoded-blob
      # note. A 32-byte key is 44 base64 chars, comfortably over. See {#body_blob_note}.
      BLOB_JOIN_MIN = 32

      # The standard base64 alphabet. Excludes base64url's +-+/+_+ on purpose:
      # those collide with hyphenated labels and +snake_case+ identifiers common
      # in honest mail, whereas +++ +/+ +=+ never appear in prose tokens. Cost:
      # base64url/JWT-shaped payloads slip by — accepted, per {#body_blob_note}.
      BLOB_ALPHABET = %r{\A[A-Za-z0-9+/=]+\z}

      # Single-case hex — what a key already wears on disk. Mixed case is absent
      # on purpose: that is three-class, so {BLOB_ALPHABET} has it. No interior
      # +-+, so a dashed UUID matches nothing here.
      HEX_ALPHABET = /\A(?:[a-f0-9]+|[A-F0-9]+)\z/

      # RFC-4648 base32; single-case like {HEX_ALPHABET}, so it shares the
      # longer thresholds below.
      BASE32_ALPHABET = /\A[A-Z2-7]+=*\z/

      # {BLOB_TOKEN_MIN}'s twin for the single-alphabet encodings, doubled: a
      # one-alphabet run is likelier to be an honest identifier than a base64
      # run is, so it must be twice as long to count.
      SINGLE_CLASS_TOKEN_MIN = 32

      # {BLOB_JOIN_MIN}'s twin, in the only gap available: above a full git
      # SHA-1 (40), below a 32-byte key in base32 (52) or hex (64). Accepts one
      # irreducible false positive — a lone SHA-256 checksum warns, since a
      # 256-bit hash and a 256-bit key are the same string (+D_blob_spotter_alphabets+).
      SINGLE_CLASS_JOIN_MIN = 48

      # The outcome of checking one compose request.
      #
      # * +ok+ — +false+ only when a body flag forced a fail-closed abort.
      # * +error+ — the fail-closed message ({String}), present iff +ok+ is false.
      # * +to+ / +cc+ / +bcc+ — {Array}<{String}> addresses that passed the hard
      #   checks (rejected fields come back empty).
      # * +subject+ — the {String} subject, or +nil+ (absent, or dropped on a flag).
      # * +body+ — the {String} body when +ok+ (guaranteed clean), else +nil+.
      # * +notes+ — {Array}<{String}> human-facing warnings (dropped fields +
      #   novelty) for the observation.
      Verdict = Data.define(:ok, :error, :to, :cc, :bcc, :subject, :body, :notes)

      # @param backend [Gloda::Contacts, nil] contact resolver for the novelty
      #   check; +nil+ disables it (the verdict then carries a "couldn't check"
      #   note).
      # @return [ComposeGuard]
      def initialize(backend: nil)
        @backend = backend
      end

      # Check one compose request and return a {Verdict}.
      #
      # @param to [String] recipient address(es), comma-separated.
      # @param cc [String, nil] Cc address(es), comma-separated.
      # @param bcc [String, nil] Bcc address(es), comma-separated.
      # @param subject [String, nil] subject line.
      # @param body [String] plain-text body.
      # @return [Verdict]
      def check(to:, body:, cc: nil, bcc: nil, subject: nil)
        body_res = Pikuri::Sanitizer.sanitize(body.to_s)
        unless body_res.warnings.empty?
          return Verdict.new(ok: false, error: body_fail_message(body_res),
                             to: [], cc: [], bcc: [], subject: nil, body: nil, notes: [])
        end

        notes = []
        kept_to  = check_addresses('To', to, notes)
        kept_cc  = check_addresses('Cc', cc, notes)
        kept_bcc = check_addresses('Bcc', bcc, notes)
        novelty_note(kept_to + kept_cc + kept_bcc, notes)
        body_blob_note(body.to_s, notes)

        Verdict.new(ok: true, error: nil, to: kept_to, cc: kept_cc, bcc: kept_bcc,
                    subject: check_subject(subject, notes),
                    body: body.to_s.empty? ? nil : body, notes: notes)
      end

      private

      # @return [String] the fail-closed observation naming the flagged classes.
      def body_fail_message(result)
        kinds = result.warnings.map(&:kind).join(', ')
        "won't compose this message — the body contains characters an outbound " \
          "mail has no honest reason to carry (#{kinds}). If this is genuinely " \
          'what you want to send, type it directly in Thunderbird.'
      end

      # @return [String, nil] the subject when clean, +nil+ when absent or dropped.
      def check_subject(subject, notes)
        return nil if subject.nil? || subject.to_s.empty?

        warnings = Pikuri::Sanitizer.sanitize(subject).warnings
        return subject if warnings.empty?

        notes << "Subject omitted (suspicious characters: #{warnings.map(&:kind).join(', ')}) — " \
                 'type it in the compose window.'
        nil
      end

      # Split a comma-separated address field and keep it only if *every*
      # address passes the hard checks; otherwise drop the whole field.
      #
      # @return [Array<String>] the vetted addresses, or +[]+ if dropped/absent.
      def check_addresses(label, field, notes)
        return [] if field.nil? || field.to_s.strip.empty?

        addrs = field.to_s.split(',').map(&:strip).reject(&:empty?)
        bad = addrs.reject { |a| address_ok?(a) }
        return addrs if bad.empty?

        notes << "#{label} omitted (couldn't safely include #{bad.map(&:inspect).join(', ')}) — " \
                 'type the recipient(s) in the compose window.'
        []
      end

      # @return [Boolean] whether one address is safe to pre-fill: ASCII-only,
      #   no +xn--+ punycode, and clean under {Pikuri::Sanitizer}.
      def address_ok?(addr)
        return false unless addr.ascii_only?
        return false if addr.downcase.include?('xn--')

        Pikuri::Sanitizer.sanitize(addr).warnings.empty?
      end

      # Append the novelty warning for any recipient domain the user has never
      # sent mail to. Best-effort: degrades to a "couldn't check" note when the
      # backend is absent, no Sent mail is indexed, or the schema differs from
      # the probed shape (it is unverified across TB versions).
      #
      # @return [void]
      def novelty_note(addrs, notes)
        domains = addrs.map { |a| a.split('@', 2).last.to_s.downcase }.reject(&:empty?).uniq
        return if domains.empty?

        unless @backend
          notes << "Couldn't check whether you've mailed these recipients before " \
                   '(mail index unavailable) — double-check the address is correct.'
          return
        end

        sent_to = @backend.domains_sent_to(domains)
        unless sent_to
          notes << "Couldn't check whether you've mailed these recipients before " \
                   '(no sent mail is indexed) — double-check the address is correct.'
          return
        end
        novel = domains - sent_to
        return if novel.empty?

        notes << "You have never sent mail to #{novel.join(', ')}. If you expected a " \
                 'familiar contact, watch for a look-alike domain and verify out of ' \
                 'band (not by replying to a suspect message).'
      rescue SQLite3::SQLException, DatabaseSnapshot::TornError => e
        LOGGER.warn("recipient-novelty check unavailable: #{e.message}")
        notes << "Couldn't check whether you've mailed these recipients before — " \
                 'double-check the address is correct.'
      end

      # Soft-warn when the body carries an encoded-looking blob: an encoded dump
      # of a secret is the easiest high-bandwidth exfil, all-printable-ASCII so
      # it passes the {Pikuri::Sanitizer} gate while the human skims past the
      # gibberish. A flagged body still composes — the note only aims the eye:
      #
      #   body_blob_note("ship it:\naGVsbG8gd29ybGQgT3BlbkFJc2VjcmV0", notes)
      #   # appends: "Line 2 onward contains encoded-looking content
      #   #           (aGVsbG8gd29ybGQgT3BlbkFJ…, 32 chars total) — verify you
      #   #           meant to send this; an encoded blob is how a secret leaks
      #   #           past a skim."
      #
      # @param body [String] the plain-text body (already {Pikuri::Sanitizer}-clean).
      # @param notes [Array<String>] accumulator, appended to in place.
      # @return [void]
      #
      # == Implementation details
      #
      # The two chunk shapes ({#blob_kind}) carry independent thresholds and the
      # body warns on whichever trips first. Summing body-wide rather than over
      # one contiguous run folds space-split and word-interleaved payloads back
      # together for free: cover words fail both gates and drop out.
      #
      # A paste / dumb-attack guard, *not* an exfil control — a prompt-injected
      # model can add "split it into 15-char pieces" for free and walk under
      # every threshold here. Hence soft-warn, and the minimums kept high to stay
      # quiet on engineering mail; the irreversible-send compose window is the
      # real backstop, so err toward not warning. Don't recast this as "closes
      # the encoded-blob channel."
      def body_blob_note(body, notes)
        hits = blob_hits(body)
        [[:mixed, BLOB_JOIN_MIN], [:single, SINGLE_CLASS_JOIN_MIN]].each do |kind, join_min|
          matched = hits.select { |hit| hit[:kind] == kind }
          total = matched.sum { |hit| hit[:token].length }
          next if total < join_min

          first = matched.first
          notes << "Line #{first[:line]} onward contains encoded-looking content " \
                   "(#{first[:token][0, 24]}…, #{total} chars total) — verify you meant " \
                   'to send this; an encoded blob is how a secret leaks past a skim.'
          break
        end
      end

      # @param body [String] the plain-text body.
      # @return [Array<Hash>] +{line: Integer, token: String, kind: Symbol}+ per
      #   blob-shaped token, in reading order.
      def blob_hits(body)
        body.split("\n").each_with_index.flat_map do |line, i|
          line.split(/\s+/).filter_map do |raw|
            tok = raw.gsub(%r{\A[^A-Za-z0-9+/=]+|[^A-Za-z0-9+/=]+\z}, '')
            kind = blob_kind(tok)
            { line: i + 1, token: tok, kind: kind } if kind
          end
        end
      end

      # @param tok [String] a whitespace-delimited token, sentence-punctuation stripped.
      # @return [Symbol, nil] +:mixed+ for >= {BLOB_TOKEN_MIN} chars of
      #   {BLOB_ALPHABET} carrying upper *and* lower *and* a digit — encoder
      #   churn no prose word (one script), Capitalized word (two), or
      #   +invoice20260722+ slug (two) shows; +:single+ for >=
      #   {SINGLE_CLASS_TOKEN_MIN} chars of {HEX_ALPHABET} or
      #   {BASE32_ALPHABET}; +nil+ when neither fits. The digit is required
      #   either way — it is what keeps an ALL-CAPS sentence out of
      #   {BASE32_ALPHABET} and a +deadbeef+-ish word out of {HEX_ALPHABET}.
      def blob_kind(tok)
        return nil unless tok.match?(/[0-9]/)

        if tok.length >= BLOB_TOKEN_MIN && tok.match?(BLOB_ALPHABET) &&
           tok.match?(/[A-Z]/) && tok.match?(/[a-z]/)
          :mixed
        elsif tok.length >= SINGLE_CLASS_TOKEN_MIN &&
              (tok.match?(HEX_ALPHABET) || tok.match?(BASE32_ALPHABET))
          :single
        end
      end
    end
  end
end
