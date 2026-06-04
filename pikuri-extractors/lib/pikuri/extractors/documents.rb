# frozen_string_literal: true

require 'tempfile'

module Pikuri
  module Extractors
    # Office-document extractor for the {Pikuri::Extractor} registry:
    # DOCX / ODT / XLSX / legacy XLS / PPTX / EPUB / RTF → Markdown,
    # by piping the document bytes through pandoc (ODF, RTF, EPUB,
    # DOCX) or markitdown (the OOXML spreadsheet/presentation arms),
    # selected per format.
    #
    # == Container first, host CLI second
    #
    # The preferred converter is a one-shot, locally-built docker
    # container ({IMAGE}, built from this gem's +docker/+ directory):
    # +docker run --rm -i --network=none --read-only --cap-drop=ALL+,
    # bytes in via stdin, Markdown out via stdout, **no volume
    # mounts**. Two reasons this beats running a host-installed
    # converter directly:
    #
    # * *Security.* These documents typically arrive via +fetch+ /
    #   +web_scrape+ — untrusted bytes — and complex format parsers
    #   are a classic exploitation surface. In the container the
    #   parser sees no network and no host filesystem; the worst a
    #   malicious document can do is produce garbage Markdown.
    # * *Reproducibility.* The Dockerfile pins pandoc (via the base
    #   image's apt) and markitdown (exact pip version); a host
    #   install is whatever version the machine happens to have.
    #
    # When docker is unavailable (binary absent or daemon down), the
    # extractor falls back to host-installed +pandoc+ / +markitdown+
    # CLIs — same stdin→stdout contract, one code path with two argv
    # builders. Which arm was picked is logged once via
    # +Pikuri.logger_for('Extractors')+.
    #
    # == Registration is explicit
    #
    # Requiring pikuri-extractors defines this class and the shared
    # {DOCUMENTS} instance but registers nothing. A host script opts
    # in with +Pikuri::Extractors::DOCUMENTS.register+, which inserts
    # the instance before the registry's terminal +Passthrough+ entry
    # (and after core's +PDF+ / +HTML+, which keep winning their
    # formats). Same opt-in philosophy as +c.add_extension+ — no
    # behavior changes by require alone.
    #
    # == Format detection
    #
    # {#matches?} claims content by normalized content-type
    # ({CONTENT_TYPES}) or by byte sniff: RTF's +{\\rtf+ prefix; for
    # zip-based formats, ODF and EPUB mandate an uncompressed
    # +mimetype+ first entry (so the literal mime string sits inside
    # the leading sample), and OOXML is recognised by the
    # +[Content_Types].xml+ entry plus a +word/+ / +ppt/+ / +xl/+
    # entry-name scan. {#extract} re-sniffs (the registry duck type
    # doesn't pass +content_type+ to +extract+); when content was
    # claimed by content-type but the sniff is blind (legacy XLS — an
    # OLE2 container whose discriminating directory sits at the end of
    # the file, past the sample), the bytes go to markitdown with no
    # format hint and its own magic-byte detection takes over. The
    # consequence: a *local* +.xls+ (no transport content-type, sniff
    # blind) is not claimed at all and keeps today's binary refusal.
    #
    # == Deliberately out of scope
    #
    # * *ODS / ODP* — neither pandoc nor markitdown reads them; the
    #   only converter that does (LibreOffice headless) costs a 2 GB+
    #   image. Excluded rather than half-supported.
    # * *Image OCR / audio transcription* — markitdown's optional
    #   arms need model downloads; the converter image stays
    #   networkless and small. A multi-modal main LLM is the pikuri
    #   answer to images.
    # * *PDF* — stays on pikuri-core's in-process +Extractor::PDF+
    #   (lazy +extract_lines+ paging; markitdown's pdfminer arm would
    #   be no better). When pdf-reader eventually moves out of core
    #   into its own opt-in gem, the container grows a PDF arm and
    #   the host script chooses per wiring.
    #
    # == Paging economics
    #
    # A subprocess converter needs the whole document before it can
    # emit anything, so there is no lazy parse: every
    # +Extractor.extract_paged+ call (each +Read+ page of a long DOCX)
    # re-runs the full conversion. Accepted — no result cache in v1.
    # {#extract_lines} still streams: the converter's stdout lands in
    # a Tempfile (also what makes the stdin/stdout pumping
    # deadlock-free — see {Pikuri::Subprocess.run}) and lines are
    # yielded from disk, so the full Markdown String is never resident
    # during paging.
    class Documents
      # @return [Logger] gem-wide diagnostics logger.
      LOGGER = Pikuri.logger_for('Extractors')

      # @return [String] converter image tag. Version-tied so a gem
      #   upgrade rebuilds with the new pins; +pikuri-internal-+
      #   prefix matches the container-naming convention of the
      #   vectordb/memory supervisors.
      IMAGE = "pikuri-internal-extractors:#{Pikuri::VERSION}"

      # @return [String] absolute path to the shipped docker build
      #   context (Dockerfile + convert.sh).
      DOCKER_DIR = File.expand_path('../../../docker', __dir__)

      # @return [String] coreutils-+timeout+ budget for one
      #   conversion. Generous — a huge PPTX through markitdown can
      #   take a while — but bounded, so a wedged converter can't
      #   hang the agent loop.
      CONVERT_TIMEOUT = '300s'

      # @return [String] sentinel format meaning "let markitdown's
      #   magic-byte detection decide" — the fallback when content was
      #   claimed by content-type but the byte sniff is blind.
      AUTO = 'auto'

      # @return [Hash{String => String}] normalized content-type →
      #   format tag (the tag doubles as the container entrypoint's
      #   dispatch argument and pandoc's +-f+ / markitdown's +-x+
      #   value).
      CONTENT_TYPES = {
        'application/vnd.oasis.opendocument.text' => 'odt',
        'application/rtf' => 'rtf',
        'text/rtf' => 'rtf',
        'application/epub+zip' => 'epub',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document' => 'docx',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' => 'xlsx',
        'application/vnd.ms-excel' => 'xls',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation' => 'pptx'
      }.freeze

      # @return [Hash{String => Array<Symbol>}] format tag → host CLIs
      #   that can convert it, in preference order. Mirrors the
      #   container entrypoint's dispatch (+docker/convert.sh+) — keep
      #   the two in sync. pandoc leads where both could serve (DOCX,
      #   EPUB): its readers preserve more structure.
      HOST_CONVERTERS = {
        'odt'  => %i[pandoc],
        'rtf'  => %i[pandoc],
        'epub' => %i[pandoc markitdown],
        'docx' => %i[pandoc markitdown],
        'xlsx' => %i[markitdown],
        'xls'  => %i[markitdown],
        'pptx' => %i[markitdown],
        AUTO   => %i[markitdown]
      }.freeze

      # @return [String] zip local-file-header magic, shared by every
      #   OOXML / ODF / EPUB document.
      ZIP_MAGIC = "PK\x03\x04".b

      # @return [Symbol] kind tag carried on +Extractor::Page#kind+.
      def kind
        :document
      end

      # Claim content this extractor can convert: a recognised
      # content-type, or a positive byte sniff (see "Format detection"
      # in the class docs).
      #
      # @param sample [String] leading bytes of the content.
      # @param content_type [String, nil] normalized content-type, or
      #   +nil+ when the transport carries none (local files).
      # @return [Boolean]
      def matches?(sample:, content_type:)
        CONTENT_TYPES.key?(content_type) || !sniff(sample).nil?
      end

      # Convert the whole document behind +io+ to one Markdown String.
      #
      # @param io [IO, StringIO] seekable IO positioned at the start.
      # @return [String] Markdown-flavoured UTF-8 text.
      # @raise [Pikuri::Extractor::Error] when no converter is
      #   available, the conversion exits non-zero, or it times out.
      def extract(io)
        with_converted(io.read) { |file| file.read }
      end

      # Same content as {#extract}, as a stream of +chomp+ed lines
      # read off the converter's stdout Tempfile — the whole-document
      # conversion still runs up front (subprocess converters can't
      # parse lazily), but the Markdown never materialises as one
      # String. The enumerator owns the Tempfile and deletes it when
      # iteration ends.
      #
      # @param io [IO, StringIO] seekable IO positioned at the start.
      # @return [Enumerator<String>]
      # @raise [Pikuri::Extractor::Error] as for {#extract}, raised on
      #   first consumption.
      def extract_lines(io)
        bytes = io.read
        Enumerator.new do |yielder|
          with_converted(bytes) do |file|
            file.each_line { |line| yielder << line.chomp }
          end
        end
      end

      # Plug this extractor into {Pikuri::Extractor.registry}, before
      # the terminal +Passthrough+ entry. Idempotent — a second call
      # is a no-op.
      #
      # @return [Documents] self, for chaining.
      def register
        registry = Pikuri::Extractor.registry
        registry.insert(-2, self) unless registry.include?(self)
        self
      end

      # Build the converter image now if it isn't present — for host
      # scripts that prefer paying the one-time build (pip install +
      # apt, minutes) at boot rather than mid-conversation. Entirely
      # optional: {#extract} builds lazily on first use otherwise.
      #
      # @return [void]
      # @raise [Pikuri::Extractor::Error] when docker is unavailable
      #   or the build fails.
      def ensure_image!
        raise Pikuri::Extractor::Error, '`docker` is unavailable; cannot build the converter image' unless docker?

        image_ready!
        nil
      end

      private

      # Byte-sniff +sample+ to a format tag, or +nil+ when nothing
      # recognisable. ODF / EPUB ride their mandated uncompressed
      # +mimetype+ first zip entry; OOXML rides +[Content_Types].xml+
      # plus an entry-name scan (the distinctive +word/+ / +ppt/+ /
      # +xl/+ names almost always appear within the sample, the first
      # entries being small).
      #
      # @param sample [String]
      # @return [String, nil]
      def sniff(sample)
        s = sample.b
        return 'rtf' if s.start_with?('{\rtf')
        return nil unless s.start_with?(ZIP_MAGIC)
        return 'odt'  if s.include?('mimetypeapplication/vnd.oasis.opendocument.text')
        return 'epub' if s.include?('mimetypeapplication/epub+zip')
        return nil unless s.include?('[Content_Types].xml')
        return 'docx' if s.include?('word/')
        return 'pptx' if s.include?('ppt/')
        return 'xlsx' if s.include?('xl/')

        nil
      end

      # Convert +bytes+, yield the rewound stdout Tempfile, delete it.
      #
      # @param bytes [String] the whole document.
      # @yieldparam file [Tempfile] converter stdout, rewound.
      # @return [Object] the block's value.
      def with_converted(bytes)
        file = convert(bytes.b)
        begin
          yield file
        ensure
          file.close!
        end
      end

      # Run one conversion: sniff the format (falling back to {AUTO}),
      # build the argv for the resolved arm, pipe +bytes+ through it
      # with stdout landing in a Tempfile.
      #
      # @param bytes [String] the whole document (binary encoding).
      # @return [Tempfile] rewound, holding the Markdown.
      # @raise [Pikuri::Extractor::Error] on conversion failure.
      def convert(bytes)
        format = sniff(bytes[0, FileType::SAMPLE_BYTES] || +'') || AUTO
        argv = converter_argv(format)
        out = Tempfile.new(['pikuri-extractors', '.md'])
        begin
          result = Pikuri::Subprocess.run(
            'timeout', '--signal=TERM', '--kill-after=5s', CONVERT_TIMEOUT, *argv,
            stdin_data: bytes, stdout: out, chdir: '/'
          )
          unless result.status.success?
            raise Pikuri::Extractor::Error,
                  "document conversion (#{format}) failed " \
                  "(exit #{result.status.exitstatus}): #{stderr_tail(result.output)}"
          end
          out.rewind
          out
        rescue StandardError
          out.close!
          raise
        end
      end

      # The argv for one conversion of +format+ — the container when
      # docker is up (building the image first if needed), else the
      # first present host CLI for the format.
      #
      # @param format [String] format tag (or {AUTO}).
      # @return [Array<String>]
      # @raise [Pikuri::Extractor::Error] when no arm is available.
      def converter_argv(format)
        if docker?
          return ['docker', 'run', '--rm', '-i', '--network=none', '--read-only',
                  '--cap-drop=ALL', '--security-opt', 'no-new-privileges',
                  '--tmpfs', '/tmp', image_ready!, format]
        end

        backend = HOST_CONVERTERS.fetch(format).find { |cli| cli?(cli.to_s) }
        unless backend
          raise Pikuri::Extractor::Error,
                "no converter available for #{format}: install docker (recommended — " \
                "sandboxed, pinned versions) or a host #{HOST_CONVERTERS.fetch(format).join(' / ')} CLI"
        end
        host_argv(backend, format)
      end

      # @param backend [Symbol] +:pandoc+ or +:markitdown+.
      # @param format [String] format tag (or {AUTO}).
      # @return [Array<String>] host-CLI argv, same stdin→stdout
      #   contract as the container.
      def host_argv(backend, format)
        case backend
        when :pandoc then ['pandoc', '-f', format, '-t', 'gfm', '--wrap=none']
        when :markitdown then format == AUTO ? ['markitdown'] : ['markitdown', '-x', format]
        else raise "unknown converter backend #{backend.inspect}" # pikuri bug
        end
      end

      # Is a usable docker (binary on PATH *and* daemon answering)
      # available? Probed once, memoized, choice logged.
      #
      # @return [Boolean]
      def docker?
        unless defined?(@docker)
          @docker = begin
            docker_cmd('info').status.success?
          rescue Errno::ENOENT
            false
          end
          LOGGER.info(@docker ? 'docker available — converting in the sandboxed container' \
                              : 'docker unavailable — falling back to host pandoc/markitdown')
        end
        @docker
      end

      # Make sure {IMAGE} exists locally, building from {DOCKER_DIR}
      # on first need. Memoized after one successful check.
      #
      # @return [String] {IMAGE}, for inlining into the run argv.
      # @raise [Pikuri::Extractor::Error] when the build fails.
      def image_ready!
        return IMAGE if @image_ready

        unless docker_cmd('image', 'inspect', IMAGE).status.success?
          LOGGER.info("building #{IMAGE} from #{DOCKER_DIR} (one-time, may take minutes)")
          build = docker_cmd('build', '-t', IMAGE, DOCKER_DIR)
          unless build.status.success?
            raise Pikuri::Extractor::Error,
                  "docker build of #{IMAGE} failed: #{stderr_tail(build.output)}"
          end
        end
        @image_ready = true
        IMAGE
      end

      # @param argv [Array<String>] docker subcommand + args.
      # @return [Pikuri::Subprocess::Result]
      def docker_cmd(*argv)
        Pikuri::Subprocess.spawn('docker', *argv, chdir: '/').wait
      end

      # Is +name --version+ runnable on the host? Probed once per
      # name, memoized.
      #
      # @param name [String] CLI binary name.
      # @return [Boolean]
      def cli?(name)
        @clis ||= {}
        return @clis[name] if @clis.key?(name)

        @clis[name] = begin
          Pikuri::Subprocess.spawn(name, '--version', chdir: '/').wait.status.success?
        rescue Errno::ENOENT
          false
        end
      end

      # Last ~500 chars of converter diagnostics, for an
      # LLM-presentable error message.
      #
      # @param text [String, nil]
      # @return [String]
      def stderr_tail(text)
        t = text.to_s.strip
        return '(no diagnostics)' if t.empty?

        t.length > 500 ? "...#{t[-500..]}" : t
      end
    end

    # The shared, host-script-facing instance: call
    # +Pikuri::Extractors::DOCUMENTS.register+ to plug it into the
    # registry. One instance is right — its only state is memoized
    # environment probes (docker? / image built / host CLIs), true
    # process-wide.
    DOCUMENTS = Documents.new
  end
end
