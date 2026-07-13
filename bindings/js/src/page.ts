/**
 * Conversion of public page settings into the point-based WASM contract.
 *
 * @packageDocumentation
 */

import type { LengthUnit, Margin, PageOptions } from "./types.js";

/** Page box and margins normalized to PDF points in CSS edge order. */
export interface NormalizedPage {
  widthPoints: number;
  heightPoints: number;
  marginTopPoints: number;
  marginRightPoints: number;
  marginBottomPoints: number;
  marginLeftPoints: number;
}

const PAGE_SIZES = {
  a4: [595.2756, 841.8898],
  letter: [612, 792],
} as const;

const POINTS_PER_UNIT: Record<LengthUnit, number> = {
  pt: 1,
  px: 0.75,
  mm: 72 / 25.4,
  cm: 72 / 2.54,
  in: 72,
};

/**
 * Resolves named or custom page geometry and validates a positive content box.
 *
 * @remarks
 * Named formats retain their physical size regardless of `unit`; the unit only
 * scales custom dimensions and margins.
 */
export function normalizePage(options: PageOptions = {}): NormalizedPage {
  const unit = options.unit ?? "pt";
  const scale = POINTS_PER_UNIT[unit];
  const format = options.format ?? "a4";
  const rawSize = typeof format === "string" ? PAGE_SIZES[format] : [format[0] * scale, format[1] * scale];
  let width = rawSize[0];
  let height = rawSize[1];
  if ((options.orientation ?? "portrait") === "landscape") [width, height] = [height, width];

  const [top, right, bottom, left] = normalizeMargins(options.margin ?? 0).map((value) => value * scale) as [number, number, number, number];
  if (top + bottom >= height || left + right >= width) {
    throw new RangeError("Page margins must leave a positive content area");
  }

  return {
    widthPoints: width,
    heightPoints: height,
    marginTopPoints: top,
    marginRightPoints: right,
    marginBottomPoints: bottom,
    marginLeftPoints: left,
  };
}

function normalizeMargins(margin: Margin): [number, number, number, number] {
  if (typeof margin === "number") return [margin, margin, margin, margin];
  if (margin.length === 2) return [margin[0], margin[1], margin[0], margin[1]];
  // html2pdf.js uses [top, left, bottom, right]. Normalize to CSS edge order.
  return [margin[0], margin[3], margin[2], margin[1]];
}
