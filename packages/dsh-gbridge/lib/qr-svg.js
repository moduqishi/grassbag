/**
 * Zero-dependency ISO/IEC 18004 QR Code encoder (Byte mode, ECC Level M, Versions 1..10).
 * Supports payloads up to 213 UTF-8 bytes — ideal for LAN/Tailscale pairing URLs & tokens.
 * Exports `encodeQrMatrix(text)` and `renderQrSvg(text, options)`.
 */

// Version 1..10 tables for Error Correction Level M:
// [totalCodewords, ecCodewordsPerBlock, group1Blocks, group1DataCw, group2Blocks, group2DataCw, alignCoords]
const VERSION_TABLE_M = [
  null,
  [26, 10, 1, 16, 0, 0, []],
  [44, 16, 1, 28, 0, 0, [6, 18]],
  [70, 26, 1, 44, 0, 0, [6, 22]],
  [100, 18, 2, 32, 0, 0, [6, 26]],
  [134, 24, 2, 43, 0, 0, [6, 30]],
  [172, 16, 4, 27, 0, 0, [6, 34]],
  [196, 18, 4, 31, 0, 0, [6, 22, 38]],
  [242, 22, 2, 38, 2, 39, [6, 24, 42]],
  [292, 22, 3, 36, 2, 37, [6, 26, 46]],
  [346, 26, 4, 43, 1, 44, [6, 28, 50]],
];

// Precompute GF(256) exp/log tables with primitive polynomial 0x11d.
const GF_EXP = new Uint8Array(512);
const GF_LOG = new Uint8Array(256);
{
  let x = 1;
  for (let i = 0; i < 255; i++) {
    GF_EXP[i] = x;
    GF_LOG[x] = i;
    x <<= 1;
    if (x & 0x100) x ^= 0x11d;
  }
  for (let i = 255; i < 512; i++) {
    GF_EXP[i] = GF_EXP[i - 255];
  }
}

function gfMul(a, b) {
  if (a === 0 || b === 0) return 0;
  return GF_EXP[GF_LOG[a] + GF_LOG[b]];
}

const rsGenCache = new Map();
function rsGeneratorPoly(degree) {
  let poly = rsGenCache.get(degree);
  if (poly) return poly;
  poly = [1];
  for (let i = 0; i < degree; i++) {
    const next = new Array(poly.length + 1).fill(0);
    const factor = GF_EXP[i];
    for (let j = 0; j < poly.length; j++) {
      next[j] ^= poly[j];
      next[j + 1] ^= gfMul(poly[j], factor);
    }
    poly = next;
  }
  rsGenCache.set(degree, poly);
  return poly;
}

function rsComputeEc(data, ecLen) {
  const gen = rsGeneratorPoly(ecLen);
  const rem = new Uint8Array(ecLen);
  for (let i = 0; i < data.length; i++) {
    const factor = data[i] ^ rem[0];
    for (let j = 0; j < ecLen - 1; j++) {
      rem[j] = rem[j + 1] ^ gfMul(gen[j + 1], factor);
    }
    rem[ecLen - 1] = gfMul(gen[ecLen], factor);
  }
  return rem;
}

function selectVersion(byteLen) {
  for (let v = 1; v < VERSION_TABLE_M.length; v++) {
    const [, , g1b, g1d, g2b, g2d] = VERSION_TABLE_M[v];
    const totalDataCw = g1b * g1d + g2b * g2d;
    const countBits = v <= 9 ? 8 : 16;
    const capacityBits = totalDataCw * 8;
    const neededBits = 4 + countBits + byteLen * 8;
    if (neededBits <= capacityBits) return v;
  }
  throw new RangeError(`QR payload too long (${byteLen} bytes > max 213 bytes for V10-M)`);
}

function encodeCodewords(bytes, version) {
  const [, ecPerBlock, g1b, g1d, g2b, g2d] = VERSION_TABLE_M[version];
  const totalDataCw = g1b * g1d + g2b * g2d;
  const countBits = version <= 9 ? 8 : 16;

  const bits = [];
  const pushBits = (val, len) => {
    for (let i = len - 1; i >= 0; i--) bits.push((val >>> i) & 1);
  };

  // Byte mode indicator (0100)
  pushBits(0b0100, 4);
  pushBits(bytes.length, countBits);
  for (const b of bytes) pushBits(b, 8);

  // Terminator (up to 4 zero bits)
  const capBits = totalDataCw * 8;
  const term = Math.min(4, capBits - bits.length);
  for (let i = 0; i < term; i++) bits.push(0);

  // Pad to byte boundary
  while (bits.length % 8 !== 0) bits.push(0);

  const dataCw = [];
  for (let i = 0; i < bits.length; i += 8) {
    let byte = 0;
    for (let j = 0; j < 8; j++) byte = (byte << 1) | bits[i + j];
    dataCw.push(byte);
  }

  // Pad alternating 0xEC / 0x11
  const padBytes = [0xec, 0x11];
  let padIdx = 0;
  while (dataCw.length < totalDataCw) {
    dataCw.push(padBytes[padIdx++ & 1]);
  }

  // Split into RS blocks
  const dataBlocks = [];
  const ecBlocks = [];
  let offset = 0;
  for (let i = 0; i < g1b; i++) {
    const blk = dataCw.slice(offset, offset + g1d);
    offset += g1d;
    dataBlocks.push(blk);
    ecBlocks.push(rsComputeEc(blk, ecPerBlock));
  }
  for (let i = 0; i < g2b; i++) {
    const blk = dataCw.slice(offset, offset + g2d);
    offset += g2d;
    dataBlocks.push(blk);
    ecBlocks.push(rsComputeEc(blk, ecPerBlock));
  }

  // Interleave data codewords, then EC codewords
  const out = [];
  const maxDataLen = Math.max(g1d, g2d);
  for (let i = 0; i < maxDataLen; i++) {
    for (const blk of dataBlocks) {
      if (i < blk.length) out.push(blk[i]);
    }
  }
  for (let i = 0; i < ecPerBlock; i++) {
    for (const ec of ecBlocks) {
      out.push(ec[i]);
    }
  }
  return out;
}

function computeFormatBits(maskPattern) {
  // ECC Level M = 00
  const data = (0b00 << 3) | (maskPattern & 7);
  let rem = data << 10;
  const poly = 0x537;
  for (let i = 14; i >= 10; i--) {
    if ((rem >>> i) & 1) rem ^= poly << (i - 10);
  }
  return ((data << 10) | rem) ^ 0x5412;
}

function computeVersionBits(version) {
  let rem = version << 12;
  const poly = 0x1f25;
  for (let i = 17; i >= 12; i--) {
    if ((rem >>> i) & 1) rem ^= poly << (i - 12);
  }
  return (version << 12) | rem;
}

function createBaseMatrix(version) {
  const size = version * 4 + 17;
  const modules = Array.from({ length: size }, () => new Uint8Array(size));
  const isFunc = Array.from({ length: size }, () => new Uint8Array(size));

  const setFunc = (r, c, dark) => {
    if (r < 0 || r >= size || c < 0 || c >= size) return;
    modules[r][c] = dark ? 1 : 0;
    isFunc[r][c] = 1;
  };

  // Finder patterns + separators
  const drawFinder = (top, left) => {
    for (let dr = -1; dr <= 7; dr++) {
      for (let dc = -1; dc <= 7; dc++) {
        const r = top + dr;
        const c = left + dc;
        if (r < 0 || r >= size || c < 0 || c >= size) continue;
        const inOuter = dr >= 0 && dr <= 6 && dc >= 0 && dc <= 6;
        const onBorder = dr === 0 || dr === 6 || dc === 0 || dc === 6;
        const inCore = dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4;
        setFunc(r, c, inOuter && (onBorder || inCore));
      }
    }
  };
  drawFinder(0, 0);
  drawFinder(0, size - 7);
  drawFinder(size - 7, 0);

  // Timing patterns
  for (let i = 8; i < size - 8; i++) {
    setFunc(6, i, i % 2 === 0);
    setFunc(i, 6, i % 2 === 0);
  }

  // Alignment patterns
  const coords = VERSION_TABLE_M[version][6];
  for (const ar of coords) {
    for (const ac of coords) {
      if (isFunc[ar][ac]) continue;
      for (let dr = -2; dr <= 2; dr++) {
        for (let dc = -2; dc <= 2; dc++) {
          const dist = Math.max(Math.abs(dr), Math.abs(dc));
          setFunc(ar + dr, ac + dc, dist !== 1);
        }
      }
    }
  }

  // Reserve format info areas + dark module
  for (let i = 0; i < 9; i++) {
    if (i !== 6) {
      setFunc(8, i, false);
      setFunc(i, 8, false);
    }
  }
  for (let i = 0; i < 8; i++) {
    setFunc(8, size - 1 - i, false);
    setFunc(size - 1 - i, 8, false);
  }
  setFunc(size - 8, 8, true);

  // Version info (Versions 7+)
  if (version >= 7) {
    const vBits = computeVersionBits(version);
    for (let i = 0; i < 18; i++) {
      const bit = Boolean((vBits >>> i) & 1);
      const r = Math.floor(i / 3);
      const c = size - 11 + (i % 3);
      setFunc(r, c, bit);
      setFunc(c, r, bit);
    }
  }

  return { size, modules, isFunc };
}

function placeDataBits(size, modules, isFunc, codewords) {
  let bitIdx = 0;
  const totalBits = codewords.length * 8;
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5; // skip vertical timing column
    const upward = ((right + 1) & 2) === 0;
    for (let vert = 0; vert < size; vert++) {
      const r = upward ? size - 1 - vert : vert;
      for (let j = 0; j < 2; j++) {
        const c = right - j;
        if (isFunc[r][c]) continue;
        let bit = 0;
        if (bitIdx < totalBits) {
          bit = (codewords[bitIdx >>> 3] >>> (7 - (bitIdx & 7))) & 1;
          bitIdx++;
        }
        modules[r][c] = bit;
      }
    }
  }
}

function maskBit(mask, r, c) {
  switch (mask) {
    case 0: return ((r + c) & 1) === 0;
    case 1: return (r & 1) === 0;
    case 2: return c % 3 === 0;
    case 3: return (r + c) % 3 === 0;
    case 4: return (((r >>> 1) + Math.floor(c / 3)) & 1) === 0;
    case 5: return ((r * c) & 1) + ((r * c) % 3) === 0;
    case 6: return ((((r * c) & 1) + ((r * c) % 3)) & 1) === 0;
    case 7: return ((((r + c) & 1) + ((r * c) % 3)) & 1) === 0;
    default: return false;
  }
}

function writeFormatInfo(size, modules, mask) {
  const bits = computeFormatBits(mask);
  for (let i = 0; i <= 5; i++) modules[8][i] = (bits >>> i) & 1;
  modules[8][7] = (bits >>> 6) & 1;
  modules[8][8] = (bits >>> 7) & 1;
  modules[7][8] = (bits >>> 8) & 1;
  for (let i = 9; i < 15; i++) modules[14 - i][8] = (bits >>> i) & 1;

  for (let i = 0; i < 8; i++) modules[size - 1 - i][8] = (bits >>> i) & 1;
  for (let i = 8; i < 15; i++) modules[8][size - 15 + i] = (bits >>> i) & 1;
}

function evaluatePenalty(size, modules) {
  let penalty = 0;
  // Rule 1: adjacent runs >= 5
  for (let r = 0; r < size; r++) {
    let runVal = modules[r][0];
    let runLen = 1;
    for (let c = 1; c < size; c++) {
      if (modules[r][c] === runVal) {
        runLen++;
      } else {
        if (runLen >= 5) penalty += 3 + (runLen - 5);
        runVal = modules[r][c];
        runLen = 1;
      }
    }
    if (runLen >= 5) penalty += 3 + (runLen - 5);
  }
  for (let c = 0; c < size; c++) {
    let runVal = modules[0][c];
    let runLen = 1;
    for (let r = 1; r < size; r++) {
      if (modules[r][c] === runVal) {
        runLen++;
      } else {
        if (runLen >= 5) penalty += 3 + (runLen - 5);
        runVal = modules[r][c];
        runLen = 1;
      }
    }
    if (runLen >= 5) penalty += 3 + (runLen - 5);
  }
  // Rule 2: 2x2 blocks
  for (let r = 0; r < size - 1; r++) {
    for (let c = 0; c < size - 1; c++) {
      const v = modules[r][c];
      if (v === modules[r][c + 1] && v === modules[r + 1][c] && v === modules[r + 1][c + 1]) {
        penalty += 3;
      }
    }
  }
  // Rule 4: dark ratio balance
  let dark = 0;
  for (let r = 0; r < size; r++) {
    for (let c = 0; c < size; c++) dark += modules[r][c];
  }
  const pct = (dark * 100) / (size * size);
  const k = Math.floor(Math.abs(pct - 50) / 5);
  penalty += k * 10;
  return penalty;
}

/**
 * Encode arbitrary UTF-8 text into a standard QR Code matrix (`size x size` of `0 | 1`).
 */
export function encodeQrMatrix(text) {
  const bytes = Buffer.from(String(text ?? ''), 'utf8');
  const version = selectVersion(bytes.length);
  const codewords = encodeCodewords(bytes, version);
  const { size, modules, isFunc } = createBaseMatrix(version);
  placeDataBits(size, modules, isFunc, codewords);

  let bestMask = 0;
  let bestPenalty = Infinity;
  let bestGrid = null;

  for (let mask = 0; mask < 8; mask++) {
    const candidate = modules.map((row) => Uint8Array.from(row));
    for (let r = 0; r < size; r++) {
      for (let c = 0; c < size; c++) {
        if (!isFunc[r][c] && maskBit(mask, r, c)) {
          candidate[r][c] ^= 1;
        }
      }
    }
    writeFormatInfo(size, candidate, mask);
    const p = evaluatePenalty(size, candidate);
    if (p < bestPenalty) {
      bestPenalty = p;
      bestMask = mask;
      bestGrid = candidate;
    }
  }

  return {
    version,
    mask: bestMask,
    size,
    modules: bestGrid.map((row) => Array.from(row)),
  };
}

/**
 * Render a crisp, compact SVG path string for a QR matrix (`1` unit per module, quiet zone included).
 */
export function buildQrPathData(matrix, margin = 3) {
  const { size, modules } = matrix;
  const parts = [];
  for (let r = 0; r < size; r++) {
    let c = 0;
    while (c < size) {
      if (modules[r][c]) {
        const start = c;
        while (c < size && modules[r][c]) c++;
        const w = c - start;
        parts.push(`M${start + margin} ${r + margin}h${w}v1h-${w}z`);
      } else {
        c++;
      }
    }
  }
  return {
    viewBoxSize: size + margin * 2,
    pathData: parts.join(''),
  };
}

/**
 * Render a standalone high-contrast SVG QR code ready for web pages, DSH UI, or data URLs.
 */
export function renderQrSvg(text, {
  size = 220,
  margin = 3,
  dark = '#0f172a',
  light = '#ffffff',
} = {}) {
  const matrix = encodeQrMatrix(text);
  const { viewBoxSize, pathData } = buildQrPathData(matrix, margin);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${viewBoxSize} ${viewBoxSize}" shape-rendering="crispEdges" role="img" aria-label="GrassBag QR Code"><rect width="${viewBoxSize}" height="${viewBoxSize}" fill="${light}" rx="2"/><path d="${pathData}" fill="${dark}"/></svg>`;
}
