/** Render-local attachment ownership and validation shared by both backends. */
import { WasmRenderError } from "./errors.js";
import type { PdfAttachment, RenderOptions } from "./types.js";

export interface PreparedAttachment {
  name: string;
  data: Uint8Array<ArrayBuffer>;
  mimeType: string;
  relationship: NonNullable<PdfAttachment["relationship"]>;
  description?: string;
  modifiedAt?: string;
}

export interface PdfExtras {
  conformance?: RenderOptions["conformance"];
  attachments?: readonly PreparedAttachment[];
}

/** Copies just the supplied views, keeping caller buffers usable after Worker transfer. */
export function preparePdfExtras(options: Pick<RenderOptions, "conformance" | "attachments">): PdfExtras {
  if (options.conformance !== undefined && options.conformance !== "pdfa-3u") {
    fail("Unsupported PDF conformance");
  }

  const result: PdfExtras = {};
  if (options.conformance !== undefined) result.conformance = options.conformance;

  if (options.attachments === undefined) return result;
  if (!Array.isArray(options.attachments)) fail("Attachments must be an array");

  const names = new Set<string>();
  result.attachments = options.attachments.map((attachment): PreparedAttachment => {
    if (!attachment || typeof attachment.name !== "string" || !attachment.name.trim()) {
      fail("Attachment name must not be empty");
    }
    validateString(attachment.name);
    if (names.has(attachment.name)) fail(`Duplicate attachment name: ${attachment.name}`);
    names.add(attachment.name);

    const mimeType = attachment.mimeType === undefined ? "application/octet-stream" : attachment.mimeType;
    if (
      typeof mimeType !== "string" ||
      !/^[!#$%&'*+.^_`|~0-9A-Za-z-]+\/[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(mimeType)
    ) {
      fail("Invalid attachment MIME type");
    }

    const relationship = attachment.relationship === undefined ? "Unspecified" : attachment.relationship;
    if (!["Source", "Data", "Alternative", "Supplement", "Unspecified"].includes(relationship)) {
      fail("Invalid attachment relationship");
    }

    if (!(attachment.data instanceof ArrayBuffer) && !(attachment.data instanceof Uint8Array)) {
      fail("Attachment data must be an ArrayBuffer or Uint8Array");
    }

    // Copy only the supplied view so Worker transfer cannot detach the caller's buffer.
    let data: Uint8Array<ArrayBuffer>;
    try {
      data = new Uint8Array(
        attachment.data instanceof Uint8Array ? attachment.data : new Uint8Array(attachment.data),
      );
    } catch {
      return fail("Attachment buffer is detached or invalid");
    }

    const prepared: PreparedAttachment = { name: attachment.name, data, mimeType, relationship };

    if (attachment.description !== undefined) {
      validateString(attachment.description);
      prepared.description = attachment.description;
    }

    if (attachment.modifiedAt !== undefined) {
      const date = attachment.modifiedAt;
      if (
        !(date instanceof Date) ||
        !Number.isFinite(date.getTime()) ||
        date.getUTCFullYear() < 1 ||
        date.getUTCFullYear() > 9999
      ) {
        fail("Invalid attachment modification date");
      }
      prepared.modifiedAt = `D:${date.toISOString().slice(0, 19).replace(/[-:T]/g, "")}Z`;
    }

    return prepared;
  });

  return result;
}

function validateString(value: string): void {
  if (typeof value !== "string") fail("Attachment text must be a string");
  for (const character of value) {
    const cp = character.codePointAt(0)!;
    if (cp === 0 || cp === 0xfffe || cp === 0xffff || (cp >= 0xd800 && cp <= 0xdfff)) fail("Invalid attachment Unicode text");
  }
}

function fail(message: string): never { throw new WasmRenderError(message, -4); }
