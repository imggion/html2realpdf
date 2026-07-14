#!/bin/sh
set -eu

# Noto Sans is pinned to the final commit of the official noto-fonts
# distribution repository so local and CI builds use identical font bytes.
commit="ffebf8c1ee449e544955a7e813c54f9b73848eac"
base="https://raw.githubusercontent.com/notofonts/noto-fonts/${commit}/hinted/ttf"
destination="src/assets/fonts"

mkdir -p "${destination}"

fetch_font() {
    name="$1"
    expected="$2"
    family="$3"
    target="${destination}/${name}"

    curl --fail --location --silent --show-error "${base}/${family}/${name}" --output "${target}"
    actual="$(shasum -a 256 "${target}" | awk '{print $1}')"
    if [ "${actual}" != "${expected}" ]; then
        rm -f "${target}"
        echo "Checksum mismatch for ${name}" >&2
        exit 1
    fi
}

fetch_font "NotoSans-Regular.ttf" "b85c38ecea8a7cfb39c24e395a4007474fa5a4fc864f6ee33309eb4948d232d5" "NotoSans"
fetch_font "NotoSans-Bold.ttf" "c976e4b1b99edc88775377fcc21692ca4bfa46b6d6ca6522bfda505b28ff9d6a" "NotoSans"
fetch_font "NotoSans-Italic.ttf" "36cff144df01309dab648bea71baff9bb074026914afe63aeacc8bc90b67a28b" "NotoSans"
fetch_font "NotoSans-BoldItalic.ttf" "6edf4227ef0fa846aca70e86a307804ca4401741830f5b3af0f2554abe2b8466" "NotoSans"
fetch_font "NotoSansArabic-Regular.ttf" "ceea25b464a656dc3b26849bab9356740401af62aedf1bfa8b7f0d9b75925b1b" "NotoSansArabic"
fetch_font "NotoSansHebrew-Regular.ttf" "a7fa16fffb27bedb060a0866267c29e9859aeb9c21cc33f5b3aaf6eb062eca85" "NotoSansHebrew"

echo "Verified Noto Sans font assets in ${destination}"
