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
    #   ComposeGuard.new(backend: gloda).check(to: 'a@acme.com', body: 'Hi')
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
    # * *Soft warn* — the correspondence-graph novelty check: a recipient domain
    #   the user has never exchanged mail with (per {Gloda#domains_seen}) stays
    #   in the draft but earns a loud note urging out-of-band verification. A
    #   hard reject here would fire on every genuinely-new correspondent.
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

      # @param backend [Gloda, nil] mail backend for the novelty check; +nil+
      #   disables it (the verdict then carries a "couldn't check" note).
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

      # Append the correspondence-graph novelty warning for any recipient domain
      # the user has no prior mail with. Best-effort: degrades to a "couldn't
      # check" note when the backend is absent or its identity schema differs
      # from the probed shape (the schema is unverified across TB versions).
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

        seen = @backend.domains_seen(domains)
        novel = domains - seen
        return if novel.empty?

        notes << "You have no prior mail with #{novel.join(', ')}. If you expected a " \
                 'familiar contact, watch for a look-alike domain and verify out of ' \
                 'band (not by replying to a suspect message).'
      rescue SQLite3::SQLException => e
        LOGGER.warn("recipient-novelty check unavailable: #{e.message}")
        notes << "Couldn't check whether you've mailed these recipients before — " \
                 'double-check the address is correct.'
      end
    end
  end
end
