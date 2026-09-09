# WASM ABI version 2

`html2realpdf_abi_version()` returns 2. The TypeScript bridge checks the exact
version before creating a context. ABI 1 is rejected so an older binary cannot
silently ignore PDF/A or associated-file requests. Existing exported function
signatures are unchanged.

The JSON render entrypoints additionally accept:

```json
{
  "conformance": "pdfa-3u",
  "attachments": [{
    "name": "invoice.xml",
    "dataPointer": 123456,
    "dataLength": 42,
    "mimeType": "application/xml",
    "relationship": "Data",
    "description": "Original invoice data",
    "modifiedAt": "D:20260909120000Z"
  }]
}
```

Page dimensions and the existing options remain required as before. Omit
conformance for ordinary PDFs. Attachments are optional in both modes.
Dates use canonical UTC PDF syntax and are optional. Unknown conformance or
relationship values fail JSON validation. Data is binary, never JSON/base64.

The caller allocates each selected byte range with `alloc`, copies it into
linear memory, and keeps it alive through the synchronous render. The native
boundary validates pointer-plus-length in a wider integer before dereferencing;
zero-length attachments may have pointer zero. JSON options and HTML input
ranges are also checked. Allocation ownership is never transferred to the
native context; callers free all input buffers even on failure.

The result-handle contract remains unchanged: every nonzero handle can be
inspected for status, bytes, page count, error and diagnostics, then released
with `pdf_result_free`. Copy result views before freeing handles or making any
call that can grow memory. Font registrations belong to the context; attachments
belong exclusively to the individual render.
