# PDF/A-3u and associated files

`RenderOptions.conformance: "pdfa-3u"` enables archival serialization in the
existing PDF 1.7 writer. It is independent of `cssProfile` and works with the
same `PdfDocument`, main-thread/Worker renderers, and html2pdf.js `.set()` API.
Omitting the option preserves ordinary PDF bytes. Attachments alone do not
enable PDF/A.

## Writer contract

- XMP declares part 3, conformance U; title, author, subject, keywords, creator
  and producer agree with the Info dictionary. No creation timestamp is added.
- One unmodified `sRGB2014.icc` profile is referenced by a PDF/A OutputIntent.
  Its source, SHA-256 and license are recorded with the asset and in LICENSE.md.
- The two trailer IDs equal the MD5 of the serialized body on initial write.
  This is a deterministic file identifier, not an authenticity signature.
- Fonts remain embedded TrueType; subsets have deterministic unique six-letter
  prefixes. Fonts with OS/2 `fsType` no-subsetting embed fully. Restricted or
  bitmap-only embedding fails. CIDSet is omitted for PDF/A-3.
- Every used CID maps to valid Unicode, including subsequent glyphs of a
  HarfBuzz cluster. ActualText retains the logical text once. Body, SVG and
  margin-box text share these checks. The ordinary spacing helper is unchanged.
- RGB/gray images, SVG, gradients, transparency and SMask remain native. CMYK
  JPEGs fail; no implicit colour conversion takes place. Links have `/F 4`.
- Page dimensions must be 3–14400 points, strings at most 32767 bytes, names
  at most 127 decoded bytes, CIDs at most 65535 and indirect objects at most
  8388607. Tj/TJ strings split without relayout. Oversized logical ActualText,
  metadata and other indivisible values fail. Deep graphics state composition
  is rejected conservatively before exceeding the 28-level limit.

## Attachments

`PdfAttachment` takes `name`, `data: ArrayBuffer | Uint8Array`, optional
`mimeType`, `relationship`, `description`, and `modifiedAt: Date`. MIME defaults
to `application/octet-stream`; relationship defaults to `Unspecified`.
Relationships are Source, Data, Alternative, Supplement and Unspecified.
Names must be nonempty and unique. Invalid UTF text, media types, relationships
or dates fail explicitly. MIME parameters are not accepted.

EmbeddedFile streams preserve original bytes without recompression. Unicode
Filespec names, MIME subtype and AFRelationship are linked from both Catalog
AF and the sorted EmbeddedFiles name tree. Params includes Size and ModDate
only when the caller supplies modifiedAt; otherwise Params is absent. Dates
are normalized to UTC with second precision and years 0001–9999.

Attachment buffers belong to one render. The browser copies exactly the
supplied view before transferring it to the Worker; caller buffers remain
usable. The bridge copies the bytes into temporary WASM allocations and frees
them, including on serialization/native failure. No attachment bytes enter
the JSON options or the persistent font context.

## Validation

For an interactive React check, run `make react` and open the Vite URL. Under
**PDF export**, choose **Ordinary PDF** or **PDF/A-3u**, optionally select a
local file and its relationship, then use **Render ref** or **Render and
preview**, followed by **Download**. The selected file is read locally and
embedded with its original name, MIME type (or `application/octet-stream`),
and modification date. Changing export options clears the previous PDF and
benchmark results; removing the attachment also clears the file input.

The React benchmark applies these options to html2realpdf; its html2pdf.js
comparison remains an ordinary PDF without attachments. File reading finishes
before timing starts. The preview does not certify PDF/A conformance; the
browser tests validate React downloads with veraPDF and recover exact file bytes.

Run `make test-pdfa` (also part of `make test-release`). It requires Java 17+,
Poppler, curl and unzip. The first run downloads veraPDF Greenfield **1.30.2**
from its official versioned URL and verifies SHA-256
`6cc6341cb1af644044054b81f00a6590a7918abb18f762243de115258bcad838`.
The installation and generated artifacts stay under ignored `tmp/pdfa/`.

The gate runs `--flavour 3u`, checks the reported version and exact expected
file set, and rejects missing/partial reports, execution failures and every
noncompliant result. Native fixtures verify actual HarfBuzz linkage. Invoice,
report, landscape, multilingual/SVG and 30-page stress fixtures cover documents
with no attachments, XML and binary files. PDF.js and Poppler verify extraction,
embedded fonts and exact file retrieval; first-page pixel comparisons guard
against visual changes. Browser E2E covers Worker, main thread and compatibility.

`tmp/pdfa/benchmark.json` compares ordinary/PDF-A with and without a 1 MiB
attachment. Each case runs in a fresh process with one warm-up and five measured
renders. Timing includes attachment copying through the final WASM output copy.
WASM linear-memory capacity and process peak RSS are reported separately; they
are capacity/high-water measurements, not precise live allocation totals.
No machine-specific timing or zero-overhead assertion is made.

Tagged PDF, PDF/UA, signatures and application formats such as Factur-X are
outside this feature. External validation is confined to tests.

## References

- [veraPDF PDF/A-2 and PDF/A-3 rules](https://github.com/veraPDF/veraPDF-validation-profiles/wiki/PDFA-Parts-2-and-3-rules)
- [ICC sRGB profile registry](https://registry.color.org/rgb-registry/srgbprofiles)
- [OpenType OS/2 embedding permissions](https://learn.microsoft.com/en-us/typography/opentype/spec/os2#fstype)
- [veraPDF CLI](https://docs.verapdf.org/cli/validation/)
