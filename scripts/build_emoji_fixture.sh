#!/bin/sh
set -eu

# Builds a tiny, renamed-by-removal monochrome emoji TTF used only by tests.
# Requires fonttools (`fonttools` and `pyftsubset`) and never ships in npm.
commit="ec0464b978de222073645d6d3366f3fdf03376d8"
source_sha256="de6c18832938afc99caf132b39d6a30a19bac7f2e812e28db2535b4608d27551"
url="https://raw.githubusercontent.com/google/fonts/${commit}/ofl/notoemoji/NotoEmoji%5Bwght%5D.ttf"
destination="tests/assets/fonts/Html2RealPdfEmojiFixture.ttf"
expected_sha256="6072cda435b264648404d1cd38ea53d422c51fa120fb9c029b8382d2f2f84261"
export SOURCE_DATE_EPOCH=315532800

temporary="$(mktemp -d)"
trap 'rm -rf "${temporary}"' EXIT INT TERM
source_font="${temporary}/NotoEmoji-wght.ttf"
static_font="${temporary}/NotoEmoji-Regular.ttf"

curl --fail --location --silent --show-error "${url}" --output "${source_font}"
actual_source="$(shasum -a 256 "${source_font}" | awk '{print $1}')"
if [ "${actual_source}" != "${source_sha256}" ]; then
    echo "Checksum mismatch for the pinned Noto Emoji source" >&2
    exit 1
fi

fonttools varLib.instancer "${source_font}" wght=400 --output="${static_font}"
mkdir -p "$(dirname "${destination}")"
pyftsubset "${static_font}" \
    --output-file="${destination}" \
    --unicodes=U+1F680,U+1F600,U+2699,U+FE0F \
    --layout-features='*' \
    --glyph-names \
    --symbol-cmap \
    --legacy-cmap \
    --notdef-glyph \
    --notdef-outline \
    --recommended-glyphs \
    --name-IDs= \
    --name-languages= \
    --no-recalc-timestamp

actual="$(shasum -a 256 "${destination}" | awk '{print $1}')"
if [ "${actual}" != "${expected_sha256}" ]; then
    rm -f "${destination}"
    echo "Generated emoji fixture differs; use fonttools 4.62.1 or review the new bytes" >&2
    exit 1
fi

echo "Built ${destination}"
