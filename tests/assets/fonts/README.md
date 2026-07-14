# Font fixtures

`Html2RealPdfEmojiFixture.ttf` is a deterministic, test-only subset derived
from the OFL-licensed Noto Emoji variable font. It contains U+1F600, U+1F680,
U+2699, and U+FE0F, with upstream name records removed so the derivative does
not use a reserved font name.

Regenerate it with `sh scripts/build_emoji_fixture.sh`. The script pins and
verifies the upstream source, fixes the variation axis at weight 400, subsets
the selected Unicode values, and checks the final SHA-256. It requires
FontTools 4.62.1 (`fonttools` and `pyftsubset`). The SIL OFL 1.1 text is in
`LICENSE.md`.
