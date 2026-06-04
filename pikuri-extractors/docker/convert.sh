#!/bin/sh
# Entrypoint dispatch for the pikuri-extractors converter image:
# $1 is the format tag, document bytes on stdin, Markdown on stdout.
# Keep the format→converter mapping in sync with
# Pikuri::Extractors::Documents::HOST_CONVERTERS — pandoc where its
# reader exists (it preserves more structure), markitdown for the
# OOXML spreadsheet/presentation arms, bare markitdown (its own
# magic-byte detection) for the `auto` fallback.
set -eu

fmt="${1:-auto}"
case "$fmt" in
  odt|rtf|epub|docx) exec pandoc -f "$fmt" -t gfm --wrap=none ;;
  xlsx|xls|pptx)     exec markitdown -x "$fmt" ;;
  auto)              exec markitdown ;;
  *) echo "pikuri-convert: unknown format tag: $fmt" >&2; exit 64 ;;
esac
