export const PDF_VIEWER_MAX_CANVAS_PIXELS = 16 * 1024 * 1024;
export const PDF_VIEWER_MAX_CANVAS_DIMENSION = 8192;
export const OCR_RASTER_MAX_CANVAS_PIXELS = 12 * 1024 * 1024;
export const OCR_RASTER_MAX_CANVAS_DIMENSION = 6144;

/**
 * Keep temporary OCR canvases inside a predictable memory budget. Scanned
 * books often embed one very large image per page; rendering those pages at a
 * fixed multiplier can otherwise allocate tens of megabytes for every OCR
 * pass before Chromium has a chance to reclaim the old canvases.
 */
export function boundedRasterScale(width, height, requestedScale, {
  maxPixels = OCR_RASTER_MAX_CANVAS_PIXELS,
  maxDimension = OCR_RASTER_MAX_CANVAS_DIMENSION
} = {}) {
  const safeWidth = Math.max(1, Number(width) || 1);
  const safeHeight = Math.max(1, Number(height) || 1);
  const desired = Math.max(0.1, Number(requestedScale) || 1);
  const pixelScale = Math.sqrt(maxPixels / (safeWidth * safeHeight));
  const dimensionScale = Math.min(maxDimension / safeWidth, maxDimension / safeHeight);
  return Math.max(0.1, Math.min(desired, pixelScale, dimensionScale));
}
