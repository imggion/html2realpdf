# XML attachment samples

Run `make react`, choose **PDF/A-3u** under **PDF export**, select one of these
files in **Attachment (optional)**, then render and download the PDF.
All data is synthetic. Each file is well-formed XML; no external schemas,
DTDs or network resources are required.

| File | What it exercises |
| --- | --- |
| `01-minimal.xml` | Small UTF-8 document, including an empty element. |
| `02-demo-invoice.xml` | Invoice-shaped data with line items and totals; a custom demo format, not FatturaPA, UBL or Factur-X. |
| `03-report-data.xml` | Channel metrics matching the playground's example report. |
| `04-unicode data-café.xml` | Spaces and accents in the filename; multiple scripts, emoji and combining characters in the content. |
| `05-namespaces.xml` | Prefixed namespaces and a nested default namespace. |
| `06-cdata-special-characters.xml` | CDATA, escaped characters, numeric references and preserved whitespace. |
| `07-utf16.xml` | UTF-16 with a BOM; the attachment must retain the original encoding and bytes. |
| `08-archive-5000-records.xml` | 5,000 deterministic records, approximately 1.38 MB, for larger-file checks. |

Choose the relationship according to the file's purpose: **Data** for report
data, **Source** for source material, **Alternative** for an alternative
representation, **Supplement** for supporting material, or **Unspecified**
for a generic attachment experiment. XML syntax and PDF/A conformance are
separate checks: the writer embeds the supplied bytes without parsing XML.
