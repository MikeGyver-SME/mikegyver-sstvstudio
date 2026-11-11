
"use strict";
/* =====================================================================
   SSTV Studio — Robot 36 / Robot 72 encoder + decoder, pure JavaScript.
   Timings and tone mapping follow the SSTV spec as implemented by nSSTV:
   VIS header, 150 ms (R36) / 300 ms (R72) lines, YCbCr (BT.601 studio
   range), 1500 Hz = black, 2300 Hz = white, 1200 Hz = sync, 1900 Hz leader.
   ===================================================================== */

const SYNC_HZ = 1200, BLACK_HZ = 1500, WHITE_HZ = 2300, LEADER_HZ = 1900;
const VIS_ONE_HZ = 1100, VIS_ZERO_HZ = 1300;
const VIS_BIT_S = 0.030, LEADER_S = 0.300, BREAK_S = 0.010;

const MODES = {
  "Robot 36": {
    vis: 8, width: 320, height: 240, color: "ycrcb420", line: 0.150, sync: 0.009,
    // channels: [key, offset_s, duration_s]; odd lines use channelsOdd
    channels: [["Y", 0.012, 0.088], ["Cr", 0.106, 0.044]],
    channelsOdd: [["Y", 0.012, 0.088], ["Cb", 0.106, 0.044]],
  },
  "Robot 72": {
    vis: 12, width: 320, height: 240, color: "ycrcb", line: 0.300, sync: 0.009,
    channels: [["Y", 0.012, 0.138], ["Cr", 0.156, 0.069], ["Cb", 0.231, 0.069]],
    channelsOdd: null,
  },
};

/* ---------------- color conversion (BT.601 studio range, as nSSTV) -------- */
function rgbToYcbcr(r, g, b) {
  const y  = 16  + (65.738 * r + 129.057 * g + 25.064 * b) / 256;
  const cr = 128 + (112.439 * r - 94.154 * g - 18.285 * b) / 256;
  const cb = 128 + (-37.945 * r - 74.494 * g + 112.439 * b) / 256;
  return [y, cr, cb];
}
function ycbcrToRgb(y, cr, cb) {
  const yy = y - 16, ry = cr - 128, by = cb - 128;
  const r = (298.082 * yy + 408.583 * ry) / 256;
  const g = (298.082 * yy - 208.120 * ry - 100.291 * by) / 256;
  const b = (298.082 * yy + 516.411 * by) / 256;
  return [r, g, b];
}
const clamp255 = v => v < 0 ? 0 : v > 255 ? 255 : v;

/* ---------------- tone synthesis (continuous phase, like ToneSynth) ------- */
function synthTones(segments, fs, amplitude) {
  // segments: array of [freqHz, seconds] or [freqArray] — here: [freq, seconds]
  let total = 0;
  const counts = segments.map(([f, s]) => { const n = Math.round(s * fs); total += n; return n; });
  const out = new Float32Array(total);
  let phase = 0, pos = 0;
  for (let i = 0; i < segments.length; i++) {
    const f = segments[i][0], n = counts[i];
    const inc = 2 * Math.PI * f / fs;
    for (let k = 0; k < n; k++) { phase += inc; out[pos++] = amplitude * Math.sin(phase); }
    phase %= 2 * Math.PI;
  }
  // 5 ms fade in/out across the whole file
  const fade = Math.min(Math.round(0.005 * fs), Math.floor(total / 2));
  for (let k = 0; k < fade; k++) { const m = k / fade; out[k] *= m; out[total - 1 - k] *= m; }
  return out;
}
// Frequency-track synthesis: freqs is a Float64Array of per-sample Hz.
function synthFreqs(freqs, fs, amplitude) {
  const out = new Float32Array(freqs.length);
  let phase = 0;
  for (let i = 0; i < freqs.length; i++) {
    phase += 2 * Math.PI * freqs[i] / fs;
    out[i] = amplitude * Math.sin(phase);
  }
  phase %= 2 * Math.PI;
  const fade = Math.min(Math.round(0.005 * fs), Math.floor(freqs.length / 2));
  for (let k = 0; k < fade; k++) { const m = k / fade; out[k] *= m; out[freqs.length - 1 - k] *= m; }
  return out;
}

/* ---------------- encoder -------------------------------------------------- */
function imageToPlanes(rgba, width, height, colorModel) {
  // rgba: Uint8ClampedArray, RGBA. Returns {Y, Cr, Cb} as Float64Array rows (height x width).
  const W = width, H = height;
  const Y = new Float64Array(W * H), Cr = new Float64Array(W * H), Cb = new Float64Array(W * H);
  for (let i = 0, p = 0; i < W * H; i++, p += 4) {
    const [y, cr, cb] = rgbToYcbcr(rgba[p], rgba[p + 1], rgba[p + 2]);
    Y[i] = y; Cr[i] = cr; Cb[i] = cb;
  }
  return { Y, Cr, Cb };
}

function encodeSSTV(rgba, width, height, modeName, sampleRate) {
  const M = MODES[modeName];
  const W = M.width, H = M.height, fs = sampleRate;
  const planes = imageToPlanes(rgba, W, H, M.color);
  const amp = 0.80;

  // Build the per-sample frequency track for the whole transmission.
  const preSil = 0.50, postSil = 0.50;
  const visDur = LEADER_S + BREAK_S + LEADER_S + 10 * VIS_BIT_S; // 0.91 s
  const imgDur = H * M.line;
  const totalSec = preSil + visDur + imgDur + postSil;
  const totalN = Math.round(totalSec * fs);
  const freqs = new Float64Array(totalN).fill(0); // 0 = silence
  let pos = Math.round(preSil * fs);

  // VIS header
  const visSegs = [];
  visSegs.push([LEADER_HZ, LEADER_S], [SYNC_HZ, BREAK_S], [LEADER_HZ, LEADER_S]);
  visSegs.push([SYNC_HZ, VIS_BIT_S]); // start bit
  const bits = [];
  for (let i = 0; i < 7; i++) bits.push((M.vis >> i) & 1);
  for (const b of bits) visSegs.push([b ? VIS_ONE_HZ : VIS_ZERO_HZ, VIS_BIT_S]);
  const parity = bits.reduce((a, b) => a + b, 0) % 2;
  visSegs.push([parity ? VIS_ONE_HZ : VIS_ZERO_HZ, VIS_BIT_S]);
  visSegs.push([SYNC_HZ, VIS_BIT_S]); // stop bit
  for (const [f, s] of visSegs) {
    const n = Math.round(s * fs);
    freqs.fill(f, pos, pos + n); pos += n;
  }

  // Image lines
  const lineN = Math.round(M.line * fs);
  for (let line = 0; line < H; line++) {
    const lineStart = pos;
    freqs.fill(BLACK_HZ, lineStart, lineStart + lineN);
    // sync pulse
    const s0 = Math.round(0 * fs), s1 = Math.round(M.sync * fs);
    freqs.fill(SYNC_HZ, lineStart + s0, lineStart + s1);
    const chans = (M.channelsOdd && line % 2 === 1) ? M.channelsOdd : M.channels;
    for (const [key, off, dur] of chans) {
      const plane = planes[key];
      const c0 = Math.round(off * fs), c1 = Math.round((off + dur) * fs);
      const rowBase = line * W;
      for (let s = c0; s < c1; s++) {
        const t = (s + 0.5) / fs;
        let pix = Math.floor((t - off) / dur * W);
        if (pix < 0) pix = 0; if (pix >= W) pix = W - 1;
        const v = plane[rowBase + pix];
        freqs[lineStart + s] = BLACK_HZ + (Math.max(0, Math.min(255, v)) / 255) * (WHITE_HZ - BLACK_HZ);
      }
    }
    pos += lineN;
  }
  // post-silence stays 0 (silence) — synth treats 0 Hz as silence.
  return synthFreqsWithSilence(freqs, fs, amp);
}

function synthFreqsWithSilence(freqs, fs, amplitude) {
  // Like synthFreqs, but freq 0 means silence (hold phase, output 0).
  const out = new Float32Array(freqs.length);
  let phase = 0;
  for (let i = 0; i < freqs.length; i++) {
    const f = freqs[i];
    if (f <= 0) { out[i] = 0; continue; }
    phase += 2 * Math.PI * f / fs;
    out[i] = amplitude * Math.sin(phase);
  }
  const fade = Math.min(Math.round(0.005 * fs), Math.floor(freqs.length / 2));
  for (let k = 0; k < fade; k++) { const m = k / fade; out[k] *= m; out[freqs.length - 1 - k] *= m; }
  return out;
}





/* =====================================================================
   Decoder DSP
   ===================================================================== */

// --- Biquad bandpass (RBJ, constant 0 dB peak gain) -----------------------
function biquadBP(fs, f0, Q) {
  const w0 = 2 * Math.PI * f0 / fs, alpha = Math.sin(w0) / (2 * Q), cos = Math.cos(w0);
  const a0 = 1 + alpha;
  return { b0: alpha / a0, b1: 0, b2: -alpha / a0, a1: -2 * cos / a0, a2: (1 - alpha) / a0 };
}
function applyBiquad(x, c) {
  const y = new Float32Array(x.length);
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  for (let i = 0; i < x.length; i++) {
    const x0 = x[i];
    const y0 = c.b0 * x0 + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2;
    y[i] = y0; x2 = x1; x1 = x0; y2 = y1; y1 = y0;
  }
  return y;
}
function bandpass900_2600(samples, fs) {
  // 4th-order Butterworth-ish bandpass, zero-phase (forward-backward).
  const f0 = Math.sqrt(900 * 2600), Q = f0 / (2600 - 900);
  const c = biquadBP(fs, f0, Q);
  let y = applyBiquad(samples, c);
  y = applyBiquad(y, c);
  // backward
  const rev = new Float32Array(y.length);
  for (let i = 0; i < y.length; i++) rev[i] = y[y.length - 1 - i];
  let z = applyBiquad(rev, c);
  z = applyBiquad(z, c);
  const out = new Float32Array(y.length);
  for (let i = 0; i < y.length; i++) out[i] = z[z.length - 1 - i];
  return out;
}

// --- Goertzel single-bin power -------------------------------------------
function goertzelPower(x, fs, freq, start, size) {
  if (start < 0) start = 0;
  if (start + size > x.length) size = x.length - start;
  if (size <= 0) return 0;
  const w = 2 * Math.PI * freq / fs, coeff = 2 * Math.cos(w);
  let s1 = 0, s2 = 0;
  for (let n = 0; n < size; n++) {
    const s0 = x[start + n] + coeff * s1 - s2;
    s2 = s1; s1 = s0;
  }
  return (s1 * s1 + s2 * s2 - coeff * s1 * s2) / (size * size);
}

// --- Zero-crossing instantaneous-frequency track --------------------------
function demodFrequency(samples, fs) {
  const n = samples.length;
  const freq = new Float32Array(n).fill(1900);
  const amp = new Float32Array(n);
  // amplitude envelope: |y| smoothed over ~0.5 ms
  const aw = Math.max(1, Math.round(0.0005 * fs));
  let run = 0;
  for (let i = 0; i < n; i++) {
    run += Math.abs(samples[i]);
    if (i >= aw) run -= Math.abs(samples[i - aw]);
    amp[i] = run / Math.min(i + 1, aw);
  }
  // rising zero crossings, sub-sample interpolated
  const cross = [];
  for (let i = 0; i + 1 < n; i++) {
    const a = samples[i], b = samples[i + 1];
    if (a <= 0 && b > 0) {
      const frac = -a / (b - a);
      cross.push(i + frac);
    }
  }
  // frequency per interval between consecutive rising crossings
  for (let k = 0; k + 1 < cross.length; k++) {
    const t0 = cross[k], t1 = cross[k + 1];
    const per = t1 - t0;
    if (per <= 0) continue;
    let f = fs / per;
    if (f < 800) f = 800; if (f > 2800) f = 2800;
    const i0 = Math.max(0, Math.floor(t0)), i1 = Math.min(n, Math.ceil(t1));
    for (let i = i0; i < i1; i++) freq[i] = f;
  }
  // 3-point median to kill outliers
  const med = new Float32Array(n);
  med[0] = freq[0]; med[n - 1] = freq[n - 1];
  for (let i = 1; i + 1 < n; i++) {
    const a = freq[i - 1], b = freq[i], c = freq[i + 1];
    med[i] = a < b ? (b < c ? b : (a < c ? c : a)) : (a < c ? a : (b < c ? c : b));
  }
  return { freq: med, amp };
}
function meanFreq(track, t0, t1, fs) {
  // amplitude-weighted mean frequency over [t0, t1) seconds
  const i0 = Math.max(0, Math.floor(t0 * fs)), i1 = Math.min(track.freq.length, Math.ceil(t1 * fs));
  if (i1 <= i0) return 1900;
  let wsum = 0, fsum = 0, usum = 0, n = 0;
  for (let i = i0; i < i1; i++) {
    const w = track.amp[i];
    wsum += w; fsum += track.freq[i] * w; usum += track.freq[i]; n++;
  }
  if (wsum > 1e-9) return fsum / wsum;
  return n ? usum / n : 1900;
}

// --- VIS header reading ----------------------------------------------------
function readVISAt(samples, fs, leaderStart) {
  // leaderStart = start of the first 1900 Hz leader tone.
  const frameStart = leaderStart + LEADER_S + BREAK_S + LEADER_S;
  const slot = VIS_BIT_S;
  const mid = (t, d) => {
    // Goertzel over the middle 20 ms of a 30 ms slot
    const s = Math.round((t + 0.005) * fs), sz = Math.round(0.020 * fs);
    return s;
  };
  const pAt = (freq, t) => {
    const s = mid(t, slot), sz = Math.round(0.020 * fs);
    return goertzelPower(samples, fs, freq, s, sz);
  };
  // start bit (slot 0) and stop bit (slot 9) should be 1200 Hz
  const start1200 = pAt(SYNC_HZ, frameStart + 0 * slot);
  const startBest = Math.max(pAt(VIS_ONE_HZ, frameStart), pAt(VIS_ZERO_HZ, frameStart));
  const stop1200 = pAt(SYNC_HZ, frameStart + 9 * slot);
  const stopBest = Math.max(pAt(VIS_ONE_HZ, frameStart + 9 * slot), pAt(VIS_ZERO_HZ, frameStart + 9 * slot));
  if (!(start1200 > startBest * 1.2 && stop1200 > stopBest * 1.2)) return null;
  let value = 0, sum = 0;
  for (let i = 0; i < 7; i++) {
    const t = frameStart + (1 + i) * slot;
    const p1 = pAt(VIS_ONE_HZ, t), p0 = pAt(VIS_ZERO_HZ, t);
    const bit = p1 > p0 ? 1 : 0;
    value |= bit << i; sum += bit;
  }
  const pt = frameStart + 8 * slot;
  const parityBit = pAt(VIS_ONE_HZ, pt) > pAt(VIS_ZERO_HZ, pt) ? 1 : 0;
  if ((sum % 2) !== parityBit) return null;
  return { code: value, visEnd: frameStart + 10 * slot };
}

function findVIS(samples, fs) {
  // Coarse scan for a 1900 Hz leader, then precise VIS read. Returns {code, visEnd, leaderStart} or null.
  const winS = 0.050, stepS = 0.100;
  const winN = Math.round(winS * fs), stepN = Math.round(stepS * fs);
  let p1900 = [];
  for (let s = 0; s + winN <= samples.length; s += stepN) {
    p1900.push([s / fs, goertzelPower(samples, fs, LEADER_HZ, s, winN)]);
  }
  if (!p1900.length) return null;
  const sorted = p1900.map(p => p[1]).sort((a, b) => a - b);
  const med = sorted[Math.floor(sorted.length / 2)] || 0;
  const thr = Math.max(med * 3, 1e-10);
  // runs of strong 1900 Hz lasting >= ~150 ms
  let runStart = -1, runLen = 0;
  const runs = [];
  for (let i = 0; i < p1900.length; i++) {
    if (p1900[i][1] > thr) {
      if (runStart < 0) { runStart = i; runLen = 1; } else runLen++;
    } else {
      if (runStart >= 0 && runLen * stepS >= 0.15) runs.push(p1900[runStart][0]);
      runStart = -1; runLen = 0;
    }
  }
  if (runStart >= 0 && runLen * stepS >= 0.15) runs.push(p1900[runStart][0]);
  for (const t of runs.slice(0, 10)) {
    // refine the leader start: fine 10 ms windows, 5 ms steps, just before the run
    let refined = Math.max(0, t - stepS);
    const fineWin = Math.round(0.010 * fs), fineStep = Math.round(0.005 * fs);
    const lo = Math.max(0, Math.round((t - 0.20) * fs)), hi = Math.min(samples.length - fineWin, Math.round((t + 0.05) * fs));
    for (let s = lo; s <= hi; s += fineStep) {
      if (goertzelPower(samples, fs, LEADER_HZ, s, fineWin) > thr) { refined = s / fs; break; }
    }
    for (const off of [0, -0.02, 0.02, -0.04, 0.04]) {
      const ls = Math.max(0, refined + off);
      const r = readVISAt(samples, fs, ls);
      if (r) return { code: r.code, visEnd: r.visEnd, leaderStart: ls };
    }
  }
  return null;
}

// --- Sync pulses (Goertzel 1200 Hz peaks — robust to noise) ----------------
function findSyncPeaks(samples, fs, searchStart, searchEnd) {
  const winN = Math.round(0.006 * fs), stepN = Math.max(1, Math.round(0.003 * fs));
  const s0 = Math.max(0, Math.floor(searchStart * fs));
  const s1 = Math.min(samples.length - winN, Math.ceil(searchEnd * fs));
  if (s1 <= s0) return [];
  const pts = [];
  for (let s = s0; s <= s1; s += stepN) pts.push([s / fs, goertzelPower(samples, fs, SYNC_HZ, s, winN)]);
  if (pts.length < 10) return [];
  const powers = pts.map(p => p[1]).sort((a, b) => a - b);
  const med = powers[Math.floor(powers.length / 2)] || 0;
  const maxP = powers[powers.length - 1] || 0;
  // Sync pulses are strong narrowband tones; black (1500 Hz) leaks a little
  // into 1200 Hz, so the threshold must sit well above that leakage.
  const thr = Math.max(med * 8, maxP * 0.08, 1e-10);
  const peaks = [];
  for (let i = 1; i + 1 < pts.length; i++) {
    if (pts[i][1] > thr && pts[i][1] >= pts[i - 1][1] && pts[i][1] >= pts[i + 1][1]) {
      const t = pts[i][0], p = pts[i][1];
      if (peaks.length && t - peaks[peaks.length - 1][0] <= 0.05) {
        if (p > peaks[peaks.length - 1][1]) peaks[peaks.length - 1] = [t, p];
      } else peaks.push([t, p]);
    }
  }
  return peaks;
}

function fitSyncGrid(peaks, linePeriod) {
  // Tracking (phase-locked) grid fit: grow from the strongest peaks, refitting
  // the period as we go. Robust to noise peaks and to a slightly-off line rate.
  if (!peaks || peaks.length < 10) return null;
  const P0 = linePeriod;
  const fitLS = (ts, ii) => {
    const n = ts.length;
    if (n < 2) return null;
    let sx = 0, sy = 0, sxx = 0, sxy = 0;
    for (let k = 0; k < n; k++) { sx += ii[k]; sy += ts[k]; sxx += ii[k] * ii[k]; sxy += ii[k] * ts[k]; }
    const den = n * sxx - sx * sx;
    if (Math.abs(den) < 1e-9) return null;
    const b = (n * sxy - sx * sy) / den, a = (sy - b * sx) / n;
    let ss = 0;
    for (let k = 0; k < n; k++) { const r = ts[k] - (a + b * ii[k]); ss += r * r; }
    return { a, b, rms: Math.sqrt(ss / n) };
  };
  // Grow a grid from one anchor peak, in both directions.
  const grow = (anchorIdx) => {
    const inliers = [{ t: peaks[anchorIdx][0], k: 0 }];
    let a = peaks[anchorIdx][0], b = P0;
    for (const dir of [1, -1]) {
      let nextK = dir, misses = 0;
      let i = dir > 0 ? anchorIdx + 1 : anchorIdx - 1;
      while (Math.abs(nextK) < 400 && misses < 5) {
        const expected = a + b * nextK;
        // nearest peak within +-20 ms of expected
        let best = -1, bestDiff = 1e9;
        if (dir > 0) {
          while (i < peaks.length && peaks[i][0] < expected - 0.02) i++;
          for (let j = i; j < peaks.length && peaks[j][0] <= expected + 0.02; j++) {
            const d = Math.abs(peaks[j][0] - expected);
            if (d < bestDiff) { bestDiff = d; best = j; }
          }
        } else {
          while (i >= 0 && peaks[i][0] > expected + 0.02) i--;
          for (let j = i; j >= 0 && peaks[j][0] >= expected - 0.02; j--) {
            const d = Math.abs(peaks[j][0] - expected);
            if (d < bestDiff) { bestDiff = d; best = j; }
          }
        }
        if (best >= 0 && bestDiff <= 0.012) {
          inliers.push({ t: peaks[best][0], k: nextK });
          const f = fitLS(inliers.map(x => x.t), inliers.map(x => x.k));
          if (f) { a = f.a; b = f.b; }
          nextK += dir;
          misses = 0;
          i = best + dir;
        } else {
          nextK += dir;
          misses++;
        }
      }
    }
    if (inliers.length < 10) return null;
    inliers.sort((x, y) => x.k - y.k);
    const f = fitLS(inliers.map(x => x.t), inliers.map(x => x.k));
    if (!f) return null;
    // k is relative to the anchor peak; shift so line 0 is the earliest sync found.
    const minK = inliers[0].k, maxK = inliers[inliers.length - 1].k;
    return { a: f.a + f.b * minK, b: f.b, count: inliers.length, rms: f.rms, lastLine: maxK - minK };
  };
  // Try the strongest peaks as anchors.
  const byPower = peaks.map((p, i) => [i, p[1]]).sort((a, b) => b[1] - a[1]);
  let best = null;
  const tried = new Set();
  for (const [ai] of byPower.slice(0, 12)) {
    if (tried.has(ai)) continue;
    tried.add(ai);
    const g = grow(ai);
    if (!g) continue;
    if (Math.abs(g.b - P0) / P0 > 0.03) continue;
    if (g.rms > 0.006) continue;
    if (!best || g.count > best.count) best = g;
    if (best && best.count >= 200) break; // full image found
  }
  return best;
}

// --- Pixel extraction & assembly -------------------------------------------
function medianOf(arr) {
  const s = [...arr].sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)];
}
function repairChromaEdges(plane, W, H, pxSec) {
  // replace first/last k chroma pixels per row with the nearest clean median
  let k = Math.ceil(0.004 / pxSec);
  k = Math.max(2, Math.min(k, Math.floor(W / 8)));
  const ref = 4;
  for (let y = 0; y < H; y++) {
    const row = y * W;
    const left = medianOf(Array.from({ length: ref }, (_, i) => plane[row + k + i]));
    const right = medianOf(Array.from({ length: ref }, (_, i) => plane[row + W - k - ref + i]));
    for (let x = 0; x < k; x++) plane[row + x] = left;
    for (let x = W - k; x < W; x++) plane[row + x] = right;
  }
  return plane;
}

function decodeSSTV(samples, sampleRate, modeHint) {
  const fs = sampleRate;
  const fileDur = samples.length / fs;
  // Find sync pulses (Goertzel) over the file (bounded to the first 10 min).
  const peaks = findSyncPeaks(samples, fs, 0, Math.min(fileDur, 600));
  if (peaks.length < 10) {
    return { ok: false, reason: "No SSTV signal found — no sync pulses locked. The audio may be noise, or too weak to decode.", mode: modeHint && modeHint !== "auto" ? modeHint : "Robot 36" };
  }
  // Try both line periods; the pulse spacing identifies the mode. Prefer the
  // user-selected mode when one is given.
  const periods = [];
  if (modeHint && modeHint !== "auto") periods.push(MODES[modeHint].line);
  if (!periods.includes(0.150)) periods.push(0.150);
  if (!periods.includes(0.300)) periods.push(0.300);
  let grid = null, gridMode = null;
  // A Robot 72 file also "fits" a 150 ms grid (300 ms is a multiple of it),
  // so collect every period that fits and pick the one whose line count is
  // closest to a full 240-line image.
  let bestScore = Infinity;
  for (const per of periods) {
    const g = fitSyncGrid(peaks, per);
    if (!g) continue;
    if (g.lastLine < 20 || g.lastLine > 280) continue;
    const score = Math.abs(g.lastLine - 239);
    if (score < bestScore) { bestScore = score; grid = g; gridMode = per === 0.150 ? "Robot 36" : "Robot 72"; }
  }
  if (!grid) {
    return { ok: false, reason: "Sync pulses found, but they don't fit a Robot 36 or Robot 72 line grid. The signal may be another SSTV mode, or too distorted.", mode: modeHint && modeHint !== "auto" ? modeHint : "Robot 36" };
  }
  const modeName = gridMode;
  const M = MODES[modeName];
  const W = M.width, H = M.height;
  const a = grid.a, b = grid.b;
  const imageStart = a; // first sync pulse = start of line 0
  // VIS read near the image start, for the status line only (mode comes from sync).
  let visCode = null;
  const vis = findVIS(samples, fs);
  if (vis && vis.code === M.vis && Math.abs(vis.visEnd - imageStart) < 2.0) visCode = vis.code;
  // Demodulate a window around the image: from ~0.2 s before image start to image end.
  const winStart = Math.max(0, imageStart - 0.2);
  const winEnd = Math.min(samples.length / fs, imageStart + H * M.line + 0.5);
  const s0 = Math.floor(winStart * fs), s1 = Math.ceil(winEnd * fs);
  let seg = samples.slice(s0, s1);
  // remove DC, bandpass, demodulate
  let mean = 0; for (let i = 0; i < seg.length; i++) mean += seg[i];
  mean /= Math.max(1, seg.length);
  for (let i = 0; i < seg.length; i++) seg[i] -= mean;
  seg = bandpass900_2600(seg, fs);
  const track = demodFrequency(seg, fs);
  const tOff = winStart; // track times are relative to winStart
  const r = b / M.line;
  const planes = { Y: new Float64Array(W * H), Cr: new Float64Array(W * H), Cb: new Float64Array(W * H) };
  const xs = new Float64Array(W); for (let x = 0; x < W; x++) xs[x] = x;
  for (let line = 0; line < H; line++) {
    const syncTime = a + b * line;
    const lineStart = syncTime; // sync_offset is 0 for both modes
    const chans = (M.channelsOdd && line % 2 === 1) ? M.channelsOdd : M.channels;
    for (const [key, off, dur] of chans) {
      const px = dur / W * r;
      for (let x = 0; x < W; x++) {
        const t0 = lineStart + off * r + x * px;
        const f = meanFreq(track, t0 - tOff, t0 + px - tOff, fs);
        let v = (f - BLACK_HZ) / (WHITE_HZ - BLACK_HZ) * 255;
        if (v < 0) v = 0; if (v > 255) v = 255;
        planes[key][line * W + x] = v;
      }
    }
  }
  // assemble RGB
  const rgba = new Uint8ClampedArray(W * H * 4);
  if (M.color === "ycrcb") {
    for (let i = 0; i < W * H; i++) {
      const [rr, gg, bb] = ycbcrToRgb(planes.Y[i], planes.Cr[i], planes.Cb[i]);
      rgba[i * 4] = clamp255(rr); rgba[i * 4 + 1] = clamp255(gg); rgba[i * 4 + 2] = clamp255(bb); rgba[i * 4 + 3] = 255;
    }
  } else {
    // ycrcb420: Cr from even lines (first real at line 2), Cb from odd lines
    const CrRows = [], CbRows = [];
    for (let l = 2; l < H; l += 2) CrRows.push(l);
    for (let l = 1; l < H; l += 2) CbRows.push(l);
    const pxSec = 0.044 / W;
    repairChromaEdges(planes.Cr, W, H, pxSec);
    repairChromaEdges(planes.Cb, W, H, pxSec);
    // luma edge repair: first/last pixel = neighbour
    for (let y = 0; y < H; y++) {
      planes.Y[y * W] = planes.Y[y * W + 1];
      planes.Y[y * W + W - 1] = planes.Y[y * W + W - 2];
    }
    const CrFull = new Float64Array(W * H), CbFull = new Float64Array(W * H);
    for (let y = 0; y < H; y++) {
      let crRow, cbRow;
      if (y < 2) crRow = CrRows.length ? CrRows[0] : 0;
      else crRow = CrRows[Math.min(CrRows.length - 1, Math.floor((y - 2) / 2))];
      cbRow = CbRows[Math.min(CbRows.length - 1, Math.floor(y / 2))];
      for (let x = 0; x < W; x++) {
        CrFull[y * W + x] = planes.Cr[crRow * W + x];
        CbFull[y * W + x] = planes.Cb[cbRow * W + x];
      }
    }
    for (let i = 0; i < W * H; i++) {
      const [rr, gg, bb] = ycbcrToRgb(planes.Y[i], CrFull[i], CbFull[i]);
      rgba[i * 4] = clamp255(rr); rgba[i * 4 + 1] = clamp255(gg); rgba[i * 4 + 2] = clamp255(bb); rgba[i * 4 + 3] = 255;
    }
  }
  return {
    ok: true, mode: modeName, rgba, width: W, height: H,
    visCode: visCode, syncCount: grid.count, syncRmsMs: grid.rms * 1000,
  };
}

/* =====================================================================
   iOS bridge — pure JavaScript (no browser APIs). Swift passes binary data
   as base64 strings and gets base64 strings back. Mode hints are normalised
   here so a capitalised "Auto" or an unknown mode can never crash the core.
   ===================================================================== */
const _B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const _B64REV = {};
for (let i = 0; i < 64; i++) _B64REV[_B64[i]] = i;
function b64ToBytes(b64) {
  const clean = b64.replace(/[^A-Za-z0-9+/=]/g, "");
  const len = clean.length;
  const pad = clean.endsWith("==") ? 2 : clean.endsWith("=") ? 1 : 0;
  const outLen = Math.floor(len * 3 / 4) - pad;
  const out = new Uint8Array(outLen);
  let p = 0;
  for (let i = 0; i < len; i += 4) {
    const a = _B64REV[clean[i]] || 0, b = _B64REV[clean[i + 1]] || 0;
    const c = _B64REV[clean[i + 2]] || 0, d = _B64REV[clean[i + 3]] || 0;
    const n = (a << 18) | (b << 12) | (c << 6) | d;
    if (p < outLen) out[p++] = (n >> 16) & 255;
    if (p < outLen) out[p++] = (n >> 8) & 255;
    if (p < outLen) out[p++] = n & 255;
  }
  return out;
}
function bytesToB64(bytes) {
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i], b = i + 1 < bytes.length ? bytes[i + 1] : 0, c = i + 2 < bytes.length ? bytes[i + 2] : 0;
    const n = (a << 16) | (b << 8) | c;
    out += _B64[(n >> 18) & 63] + _B64[(n >> 12) & 63];
    out += i + 1 < bytes.length ? _B64[(n >> 6) & 63] : "=";
    out += i + 2 < bytes.length ? _B64[n & 63] : "=";
  }
  return out;
}
// Encode a photo (RGBA bytes as base64) -> base64 float32 audio samples.
function iosEncode(rgbaB64, width, height, mode, sampleRate) {
  if (!MODES[mode]) mode = "Robot 36";
  const bytes = b64ToBytes(rgbaB64);
  const rgba = new Uint8ClampedArray(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const samples = encodeSSTV(rgba, width, height, mode, sampleRate);
  const sBytes = new Uint8Array(samples.buffer, samples.byteOffset, samples.byteLength);
  return bytesToB64(sBytes);
}
// Decode audio (float32 samples as base64) -> JSON string with the result.
function iosDecode(audioB64, sampleRate, modeHint) {
  const bytes = b64ToBytes(audioB64);
  const samples = new Float32Array(bytes.buffer, bytes.byteOffset, Math.floor(bytes.byteLength / 4));
  let hint = modeHint;
  if (!hint || (typeof hint === "string" && hint.toLowerCase() === "auto")) hint = "auto";
  if (hint !== "auto" && !MODES[hint]) hint = "auto";
  const res = decodeSSTV(samples, sampleRate, hint);
  if (!res.ok) return JSON.stringify({ ok: false, reason: res.reason, mode: res.mode });
  const rgbaBytes = new Uint8Array(res.rgba.buffer, res.rgba.byteOffset, res.rgba.byteLength);
  return JSON.stringify({
    ok: true, mode: res.mode, width: res.width, height: res.height,
    visCode: res.visCode, syncCount: res.syncCount, syncRmsMs: res.syncRmsMs,
    rgbaB64: bytesToB64(rgbaBytes)
  });
}
