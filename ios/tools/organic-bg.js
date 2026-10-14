/* organic-bg.js — hand-drawn, low-saturation backgrounds for Japanese Reader.
   Canvas 2D only: no network, no images, no dependencies. Every drawing is seeded,
   so the same scene always comes out the same (and can be redrawn natively on iOS).

   OrganicBG.paint(canvas, {scene, variant, device, density, grain, seed})  one still picture
   OrganicBG.play(canvas, opts) -> {stop()}                                  the same, gently moving
   OrganicBG.mount(host, {scene, variant, density, grain, motion})           a whole-window background
                                                       -> {canvas, update(opts), stop()}
   OrganicBG.thumb(canvas, {scene, variant})                                 a small preview
   OrganicBG.palette(scene, variant)                                         colours for the UI on top
   OrganicBG.presets()                                                       the 17 pictures as themes
   OrganicBG.scenes                                                          [{id, zh, en, variants}]

   Shared by the desktop reader (theme.js), the JLPT lessons reader (appearance.js and the
   hosted site's shell.js); the iPhone app ships pictures rendered from this same file.
*/
(function (global) {
'use strict';
const TAU = Math.PI * 2;

// ------------------------------------------------------------------ random & noise
function rng(seed) {
  let s = (seed >>> 0) || 1;
  return () => { s = s + 0x6D2B79F5 | 0; let t = Math.imul(s ^ s >>> 15, 1 | s); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
}
function hashStr(str) { let h = 2166136261 >>> 0; for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 16777619) >>> 0; } return h; }
function gauss(r) { const u = r() || 1e-9, v = r(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(TAU * v); }
function noise1(seed) {
  const r = rng(seed), v = new Float32Array(256);
  for (let i = 0; i < 256; i++) v[i] = r() * 2 - 1;
  return t => { const i = Math.floor(t), f = t - i, a = v[i & 255], b = v[(i + 1) & 255], u = f * f * (3 - 2 * f); return a + (b - a) * u; };
}
function fbm(seed, oct = 3) {
  const ns = []; for (let i = 0; i < oct; i++) ns.push(noise1(seed + i * 977));
  return t => { let s = 0, a = 1, f = 1, n = 0; for (const fn of ns) { s += fn(t * f + f * 13.7) * a; n += a; a *= .5; f *= 2.07; } return s / n; };
}
const lerp = (a, b, t) => a + (b - a) * t;
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));

// ------------------------------------------------------------------ colour
function hexRGB(h) { h = h.replace('#', ''); if (h.length === 3) h = h.split('').map(c => c + c).join(''); const n = parseInt(h, 16); return [n >> 16 & 255, n >> 8 & 255, n & 255]; }
function rgba(h, a) { const c = hexRGB(h); return 'rgba(' + c[0] + ',' + c[1] + ',' + c[2] + ',' + (a == null ? 1 : Math.round(a * 1000) / 1000) + ')'; }
function mix(a, b, t) { const x = hexRGB(a), y = hexRGB(b); return '#' + x.map((v, i) => Math.round(v + (y[i] - v) * t).toString(16).padStart(2, '0')).join(''); }

// ------------------------------------------------------------------ geometry
const dist = (a, b) => Math.hypot(b[0] - a[0], b[1] - a[1]);
function resample(pts, step) {
  if (pts.length < 2) return pts.map(p => [p[0], p[1]]);
  const out = [[pts[0][0], pts[0][1]]];
  let need = step;
  for (let i = 1; i < pts.length; i++) {
    let ax = pts[i - 1][0], ay = pts[i - 1][1];
    const bx = pts[i][0], by = pts[i][1];
    let seg = Math.hypot(bx - ax, by - ay);
    while (seg >= need) { const t = need / seg; ax += (bx - ax) * t; ay += (by - ay) * t; out.push([ax, ay]); seg -= need; need = step; }
    need -= seg;
  }
  const L = pts[pts.length - 1], o = out[out.length - 1];
  if (Math.hypot(L[0] - o[0], L[1] - o[1]) > step * .25) out.push([L[0], L[1]]);
  return out;
}
function resampleClosed(pts, step) {
  const out = resample(pts.concat([pts[0]]), step);
  if (out.length > 2 && dist(out[out.length - 1], out[0]) < step * .6) out.pop();
  return out;
}
function spline(pts, closed, seg = 10) {
  const n = pts.length; if (n < 3) return pts.map(p => [p[0], p[1]]);
  const g = i => closed ? pts[((i % n) + n) % n] : pts[Math.max(0, Math.min(n - 1, i))];
  const out = [], cnt = closed ? n : n - 1;
  for (let i = 0; i < cnt; i++) {
    const p0 = g(i - 1), p1 = g(i), p2 = g(i + 1), p3 = g(i + 2);
    for (let k = 0; k < seg; k++) {
      const t = k / seg, t2 = t * t, t3 = t2 * t;
      out.push([
        .5 * (2 * p1[0] + (-p0[0] + p2[0]) * t + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2 + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3),
        .5 * (2 * p1[1] + (-p0[1] + p2[1]) * t + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2 + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)]);
    }
  }
  if (!closed) out.push([pts[n - 1][0], pts[n - 1][1]]);
  return out;
}
function quad(a, c, b, steps = 16) {
  const out = [];
  for (let i = 0; i <= steps; i++) { const t = i / steps, u = 1 - t; out.push([u * u * a[0] + 2 * u * t * c[0] + t * t * b[0], u * u * a[1] + 2 * u * t * c[1] + t * t * b[1]]); }
  return out;
}
function normals(pts, closed) {
  const n = pts.length, out = new Array(n);
  for (let i = 0; i < n; i++) {
    const a = closed ? pts[(i - 1 + n) % n] : pts[Math.max(0, i - 1)], b = closed ? pts[(i + 1) % n] : pts[Math.min(n - 1, i + 1)];
    const dx = b[0] - a[0], dy = b[1] - a[1], l = Math.hypot(dx, dy) || 1;
    out[i] = [-dy / l, dx / l];
  }
  return out;
}
function arclen(pts) { const S = [0]; for (let i = 1; i < pts.length; i++) S.push(S[i - 1] + dist(pts[i - 1], pts[i])); return S; }
function wobble(pts, amp, freq, seed, closed) {
  if (!amp) return pts;
  const nz = fbm(seed, 2), N = normals(pts, closed), S = arclen(pts);
  let L = S[S.length - 1]; if (closed) L += dist(pts[pts.length - 1], pts[0]);
  return pts.map((p, i) => {
    let o = nz(S[i] * freq);
    if (closed && L > 0) { const u = S[i] / L; o = o * (1 - u) + nz((S[i] - L) * freq) * u; }
    o *= amp;
    return [p[0] + N[i][0] * o, p[1] + N[i][1] * o];
  });
}
function circlePts(cx, cy, r, n = 28, a0 = 0, squash = 1) {
  const out = []; for (let i = 0; i < n; i++) { const a = a0 + TAU * i / n; out.push([cx + Math.cos(a) * r, cy + Math.sin(a) * r * squash]); } return out;
}
function blobPts(cx, cy, r, seed, n = 30, rough = .12, squash = 1) {
  const nz = noise1(seed); const out = [];
  for (let i = 0; i < n; i++) { const a = TAU * i / n, k = 1 + nz(i * .55) * rough; out.push([cx + Math.cos(a) * r * k, cy + Math.sin(a) * r * k * squash]); }
  return out;
}
function poly(pts, closed = true) { const p = new Path2D(); pts.forEach((q, i) => i ? p.lineTo(q[0], q[1]) : p.moveTo(q[0], q[1])); if (closed) p.closePath(); return p; }
function shift(pts, dx, dy) { return pts.map(p => [p[0] + dx, p[1] + dy]); }
function bbox(pts) { let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity; for (const p of pts) { if (p[0] < x0) x0 = p[0]; if (p[0] > x1) x1 = p[0]; if (p[1] < y0) y0 = p[1]; if (p[1] > y1) y1 = p[1]; } return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }; }
function rotPts(pts, a, cx, cy) { const c = Math.cos(a), s = Math.sin(a); return pts.map(([x, y]) => [cx + (x - cx) * c - (y - cy) * s, cy + (x - cx) * s + (y - cy) * c]); }

// ------------------------------------------------------------------ the pen: tapered, uneven ink lines
function ribbonPath(pts, w, seed, o = {}) {
  const closed = !!o.closed, n = pts.length, p = new Path2D();
  if (n < 2) return p;
  const nz = noise1(seed * 31 + 7), N = normals(pts, closed), S = arclen(pts), L = S[n - 1];
  const t0 = o.t0 == null ? 16 : o.t0, t1 = o.t1 == null ? 22 : o.t1, press = o.pressure == null ? .32 : o.pressure, min = o.min == null ? .25 : o.min;
  const lft = [], rgt = [];
  for (let i = 0; i < n; i++) {
    let k = 1;
    if (!closed && o.taper !== false && L > 0) {
      const a = t0 ? Math.min(1, S[i] / Math.min(t0, L * .4)) : 1, b = t1 ? Math.min(1, (L - S[i]) / Math.min(t1, L * .45)) : 1;
      k = min + (1 - min) * Math.sqrt(Math.max(0, Math.min(a, b)));
    }
    const hw = w * .5 * k * (1 + press * nz(S[i] * .045));
    lft.push([pts[i][0] + N[i][0] * hw, pts[i][1] + N[i][1] * hw]);
    rgt.push([pts[i][0] - N[i][0] * hw, pts[i][1] - N[i][1] * hw]);
  }
  if (closed) {
    p.moveTo(lft[0][0], lft[0][1]); for (let i = 1; i < n; i++) p.lineTo(lft[i][0], lft[i][1]); p.closePath();
    p.moveTo(rgt[0][0], rgt[0][1]); for (let i = 1; i < n; i++) p.lineTo(rgt[i][0], rgt[i][1]); p.closePath();
  } else {
    p.moveTo(lft[0][0], lft[0][1]); for (let i = 1; i < n; i++) p.lineTo(lft[i][0], lft[i][1]);
    for (let i = n - 1; i >= 0; i--) p.lineTo(rgt[i][0], rgt[i][1]); p.closePath();
  }
  return p;
}
/** Draw a hand-inked line through pts. o: {w, color, alpha, seed, closed, amp, freq, step, sketch, t0, t1, smooth} */
function ink(ctx, pts, o) {
  const seed = o.seed || 1, step = o.step || 2.4;
  let P = o.smooth ? spline(pts, !!o.closed, o.smooth) : pts;
  P = o.closed ? resampleClosed(P, step) : resample(P, step);
  P = wobble(P, o.amp == null ? 1 : o.amp, o.freq || .035, seed, o.closed);
  const rule = o.closed ? 'evenodd' : 'nonzero';
  ctx.fillStyle = rgba(o.color, o.alpha == null ? 1 : o.alpha);
  ctx.fill(ribbonPath(P, o.w || 1.6, seed, o), rule);
  if (o.sketch) {
    const Q = wobble(P, (o.amp == null ? 1 : o.amp) * 1.2 + .45, (o.freq || .035) * 1.5, seed + 99, o.closed);
    ctx.fillStyle = rgba(o.color, (o.alpha == null ? 1 : o.alpha) * (o.sketch === true ? .34 : o.sketch));
    ctx.fill(ribbonPath(Q, (o.w || 1.6) * .55, seed + 5, Object.assign({}, o, { pressure: .5 })), rule);
  }
  return P;
}

// ------------------------------------------------------------------ paint: washes, crayon, hatching
function resampleClosedV(pts, step) { // keeps a per-vertex "looseness" in p[2]
  const out = [];
  for (let i = 0; i < pts.length; i++) {
    const a = pts[i], b = pts[(i + 1) % pts.length], L = dist(a, b), k = Math.max(1, Math.round(L / step));
    for (let j = 0; j < k; j++) { const t = j / k; out.push([lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2] == null ? 1 : a[2], b[2] == null ? 1 : b[2], t)]); }
  }
  return out;
}
function deform(P, depth, amt, r) {
  for (let d = 0; d < depth; d++) {
    const out = [];
    for (let i = 0; i < P.length; i++) {
      const a = P[i], b = P[(i + 1) % P.length], len = Math.hypot(b[0] - a[0], b[1] - a[1]), v = (a[2] + b[2]) * .5;
      out.push(a);
      out.push([(a[0] + b[0]) * .5 + gauss(r) * len * amt * v, (a[1] + b[1]) * .5 + gauss(r) * len * amt * v, v * (.7 + r() * .6)]);
    }
    P = out;
  }
  return P;
}
/** Watercolour: many faint, slightly different copies of a shape. */
function wash(ctx, pts, color, o = {}) {
  const r = rng(o.seed || 1), amt = o.amt == null ? .5 : o.amt;
  const base0 = resampleClosedV(pts.map(p => [p[0], p[1], p[2] == null ? 1 : p[2]]), o.seg || 34);
  const base = deform(base0, 1, amt * .35, r);
  ctx.save();
  if (o.blend) ctx.globalCompositeOperation = o.blend;
  ctx.fillStyle = color;
  let last = null;
  const layers = o.layers || 12;
  for (let i = 0; i < layers; i++) {
    const s = deform(base, o.depth || 3, amt * .28, r);
    ctx.globalAlpha = o.alpha == null ? .06 : o.alpha;
    last = poly(s); ctx.fill(last);
  }
  if (o.edge && last) { ctx.globalAlpha = o.edge; ctx.strokeStyle = color; ctx.lineWidth = o.edgeW || 1.1; ctx.stroke(last); }
  ctx.restore();
}
const tiles = new Map();
function seamless(S, draw) { const c = document.createElement('canvas'); c.width = c.height = S; const g = c.getContext('2d'); draw(g, S); return c; }
/** A seamless tile of short, directional dry-brush strokes. */
function crayonTile(color, seed, o = {}) {
  const key = ['c', color, seed, o.angle, o.count, o.alpha].join('|'); if (tiles.has(key)) return tiles.get(key);
  const t = seamless(160, (g, S) => {
    const r = rng(seed); g.lineCap = 'round';
    const n = o.count || 700, ang = o.angle == null ? -.32 : o.angle, al = o.alpha || [.04, .2];
    for (let i = 0; i < n; i++) {
      const x = r() * S, y = r() * S, L = 5 + r() * 20, a = ang + (r() - .5) * .3, w = .7 + r() * 2.2;
      const ex = x + Math.cos(a) * L, ey = y + Math.sin(a) * L;
      g.strokeStyle = rgba(color, al[0] + r() * (al[1] - al[0])); g.lineWidth = w;
      for (const dx of [-S, 0, S]) for (const dy of [-S, 0, S]) {
        if (Math.max(x, ex) + dx < -4 || Math.min(x, ex) + dx > S + 4 || Math.max(y, ey) + dy < -4 || Math.min(y, ey) + dy > S + 4) continue;
        g.beginPath(); g.moveTo(x + dx, y + dy); g.quadraticCurveTo((x + ex) / 2 + dx + (r() - .5) * 2, (y + ey) / 2 + dy + (r() - .5) * 2, ex + dx, ey + dy); g.stroke();
      }
    }
  });
  tiles.set(key, t); return t;
}
/** Paper speckle: tiny flecks of one colour. */
function speckTile(color, seed, density, maxA) {
  const key = ['s', color, seed, density, maxA].join('|'); if (tiles.has(key)) return tiles.get(key);
  const S = 220, c = document.createElement('canvas'); c.width = c.height = S;
  const g = c.getContext('2d'), img = g.createImageData(S, S), r = rng(seed), rgb = hexRGB(color);
  for (let i = 0; i < S * S; i++) {
    const v = r(); const a = v < density ? (r() * maxA) : 0;
    img.data[i * 4] = rgb[0]; img.data[i * 4 + 1] = rgb[1]; img.data[i * 4 + 2] = rgb[2]; img.data[i * 4 + 3] = a * 255;
  }
  g.putImageData(img, 0, 0); tiles.set(key, c); return c;
}
function pattern(ctx, tile, angle = 0, ox = 0, oy = 0, scale = 1) {
  const p = ctx.createPattern(tile, 'repeat');
  if (p.setTransform && typeof DOMMatrix !== 'undefined') p.setTransform(new DOMMatrix().translateSelf(ox, oy).rotateSelf(angle * 180 / Math.PI).scaleSelf(scale, scale));
  return p;
}
/** Fill a path with gouache: flat colour, then lighter and darker brush strokes. */
function gouache(ctx, path, color, o = {}) {
  const seed = o.seed || 1, r = rng(seed);
  ctx.save();
  ctx.fillStyle = rgba(color, o.alpha == null ? 1 : o.alpha); ctx.fill(path);
  ctx.clip(path);
  const light = o.light || mix(color, '#ffffff', .22), dark = o.dark || mix(color, '#000000', .2);
  ctx.globalAlpha = o.texture == null ? 1 : o.texture;
  ctx.fillStyle = pattern(ctx, crayonTile(light, seed, { angle: o.angle }), o.rot || 0, r() * 160, r() * 160);
  ctx.fill(path);
  ctx.fillStyle = pattern(ctx, crayonTile(dark, seed + 1, { angle: o.angle, count: 500 }), o.rot || 0, r() * 160, r() * 160);
  ctx.fill(path);
  ctx.restore();
}
function hatch(ctx, clip, box, angle, gap, color, alpha, w, seed) {
  const r = rng(seed || 3), ca = Math.cos(angle), sa = Math.sin(angle);
  const cx = box.x + box.w / 2, cy = box.y + box.h / 2, R = Math.hypot(box.w, box.h) / 2 + 6;
  const p = new Path2D();
  for (let d = -R; d <= R; d += gap * (.8 + r() * .4)) {
    const x0 = cx - ca * R - sa * d, y0 = cy - sa * R + ca * d, x1 = cx + ca * R - sa * d, y1 = cy + sa * R + ca * d;
    p.moveTo(x0, y0); p.quadraticCurveTo((x0 + x1) / 2 + (r() - .5) * 3, (y0 + y1) / 2 + (r() - .5) * 3, x1, y1);
  }
  ctx.save(); ctx.clip(clip); const bx = new Path2D(); bx.rect(box.x, box.y, box.w, box.h); ctx.clip(bx);
  ctx.strokeStyle = rgba(color, alpha); ctx.lineWidth = w || .7; ctx.lineCap = 'round'; ctx.stroke(p); ctx.restore();
}
function glow(ctx, x, y, r, color, a) {
  const g = ctx.createRadialGradient(x, y, 0, x, y, r);
  g.addColorStop(0, rgba(color, a)); g.addColorStop(.45, rgba(color, a * .35)); g.addColorStop(1, rgba(color, 0));
  ctx.fillStyle = g; ctx.fillRect(x - r, y - r, r * 2, r * 2);
}
function sprite(w, h, dpr, draw) {
  const c = document.createElement('canvas'); c.width = Math.ceil(w * dpr); c.height = Math.ceil(h * dpr);
  const g = c.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0); draw(g); c.cssW = w; c.cssH = h; return c;
}

// ------------------------------------------------------------------ paper
function paper(ctx, E) {
  const { W, H, pal } = E, r = rng(E.seed + 404);
  ctx.fillStyle = pal.paper; ctx.fillRect(0, 0, W, H);
  // uneven sizing: big soft clouds of slightly lighter / darker paper
  for (let i = 0; i < 9; i++) {
    const x = r() * W, y = r() * H, rad = (.25 + r() * .4) * Math.max(W, H);
    glow(ctx, x, y, rad, i % 2 ? mix(pal.paper, '#ffffff', .5) : mix(pal.paper, pal.ink, .5), E.dark ? .035 : .03);
  }
}
function grain(ctx, E) {
  const { W, H, pal } = E;
  ctx.save();
  ctx.globalAlpha = 1;
  ctx.fillStyle = pattern(ctx, speckTile(pal.ink, 11, .1, E.dark ? .2 : .16), .3);
  ctx.fillRect(0, 0, W, H);
  ctx.fillStyle = pattern(ctx, speckTile(E.dark ? '#ffffff' : '#ffffff', 23, .06, E.dark ? .05 : .22), -.2, 40, 70);
  ctx.fillRect(0, 0, W, H);
  // a few paper fibres
  const r = rng(E.seed + 77), n = Math.round(W * H / 26000);
  ctx.lineCap = 'round';
  for (let i = 0; i < n; i++) {
    const x = r() * W, y = r() * H, a = r() * TAU, L = 4 + r() * 10;
    ctx.strokeStyle = rgba(r() < .5 ? pal.ink : '#ffffff', E.dark ? .05 : .07); ctx.lineWidth = .5;
    ctx.beginPath(); ctx.moveTo(x, y); ctx.quadraticCurveTo(x + Math.cos(a + 1) * L * .5, y + Math.sin(a + 1) * L * .5, x + Math.cos(a) * L, y + Math.sin(a) * L); ctx.stroke();
  }
  ctx.restore();
}

// ------------------------------------------------------------------ small drawn things
function cloudOutline(x, yb, w, r) {
  // x = left, yb = bottom line, w = width; a union of round bumps traced along its upper edge
  const h = w * (.36 + r() * .08), n = 2 + (r() * 3 | 0);
  const capL = h * (.4 + r() * .1), capR = h * (.36 + r() * .1);
  const circles = [[x + capL, yb - capL, capL], [x + w - capR, yb - capR, capR]];
  const x0 = x + capL * 1.15, x1 = x + w - capR * 1.15, span = Math.max(1, x1 - x0), gap = n > 1 ? span / (n - 1) : span;
  for (let i = 0; i < n; i++) {
    const t = n > 1 ? i / (n - 1) : .5;
    const rad = clamp(gap * .62, h * .3, h * .52) * (.9 + r() * .2);
    circles.push([x0 + span * t + (r() - .5) * 6, yb - h + rad - Math.sin(Math.PI * t) * h * .1 + (r() - .5) * h * .08, rad]);
  }
  const top = [];
  for (let px = x; px <= x + w; px += 2) {
    let best = Infinity;
    for (const [cx, cy, rad] of circles) { const dx = px - cx; if (Math.abs(dx) < rad) { const y = cy - Math.sqrt(rad * rad - dx * dx); if (y < best) best = y; } }
    if (best < Infinity) top.push([px, Math.min(best, yb)]);
  }
  const out = [];
  const [lx, ly, lr] = circles[0], [rx, ry, rr] = circles[1];
  for (let a = Math.PI * .5; a <= Math.PI; a += .2) out.push([lx + Math.cos(a) * lr, ly + Math.sin(a) * lr]);
  for (const p of top) if (p[0] >= x + 1 && p[0] <= x + w - 1) out.push(p);
  for (let a = 0; a <= Math.PI * .5 + .01; a += .2) out.push([rx + Math.cos(a) * rr, ry + Math.sin(a) * rr]);
  out.push([rx, yb]);
  for (let px = rx - 8; px > lx + 4; px -= 14) out.push([px, yb + Math.sin(px * .05) * 1.2]);
  return { pts: out, h, circles };
}
function drawCloud(ctx, x, yb, w, E, o = {}) {
  const r = rng(o.seed || 5), pal = E.pal;
  const c = cloudOutline(x, yb, w, r);
  const fillPts = shift(c.pts, o.dx == null ? 3 : o.dx, o.dy == null ? 2 : o.dy);
  ctx.fillStyle = rgba(o.fill || pal.cloud, o.fillAlpha == null ? 1 : o.fillAlpha); ctx.fill(poly(fillPts));
  // pencil shading under the belly
  const clip = poly(c.pts); const b = bbox(c.pts);
  hatch(ctx, clip, { x: b.x, y: yb - c.h * .34, w: b.w, h: c.h * .4 }, -.9, 4.2, o.shade || pal.ink, o.shadeAlpha == null ? .16 : o.shadeAlpha, .7, (o.seed || 5) + 2);
  ink(ctx, c.pts, { w: o.w || 1.5 * E.lw, color: o.line || pal.ink, alpha: o.alpha == null ? .72 : o.alpha, seed: (o.seed || 5) + 1, closed: true, amp: .8, sketch: o.sketch == null ? true : o.sketch });
  return c;
}
function tuft(ctx, x, y, h, color, alpha, r, lw = 1.2) {
  const k = 3 + (r() * 3 | 0), p = new Path2D();
  for (let i = 0; i < k; i++) {
    const off = i - (k - 1) / 2, a = -Math.PI / 2 + off * .3 + (r() - .5) * .25, L = h * (.55 + r() * .55);
    const p0 = [x + off * 1.6, y], p2 = [p0[0] + Math.cos(a) * L, y + Math.sin(a) * L];
    const bend = (r() - .5) * .35 + off * .06;
    const p1 = [(p0[0] + p2[0]) / 2 + Math.cos(a + Math.PI / 2) * L * bend, (p0[1] + p2[1]) / 2 + Math.sin(a + Math.PI / 2) * L * bend];
    const pts = resample(quad(p0, p1, p2, 10), 1.5);
    const rp = ribbonPath(pts, lw * 1.25, (r() * 1e6) | 0, { t0: 0, t1: L * .9, min: .1, pressure: .2 });
    p.addPath(rp);
  }
  ctx.fillStyle = rgba(color, alpha); ctx.fill(p);
}
function star5(cx, cy, r, rot) { const out = []; for (let i = 0; i < 10; i++) { const a = rot - Math.PI / 2 + i * Math.PI / 5, rr = i % 2 ? r * .46 : r; out.push([cx + Math.cos(a) * rr, cy + Math.sin(a) * rr]); } return out; }
function sparkle(ctx, x, y, s, color, alpha, seed) {
  ink(ctx, [[x - s, y], [x + s, y]], { w: 1.1, color, alpha, seed, amp: .2, t0: 3, t1: 3 });
  ink(ctx, [[x, y - s], [x, y + s]], { w: 1.1, color, alpha, seed: seed + 1, amp: .2, t0: 3, t1: 3 });
}
function bird(ctx, x, y, s, color, alpha, seed, flap = 0) {
  const k = .55 + flap * .35;
  ink(ctx, quad([x - s, y - s * k], [x - s * .45, y - s * .1], [x, y + s * .12], 6), { w: 1.2, color, alpha, seed, amp: .15, t0: 2, t1: 1 });
  ink(ctx, quad([x, y + s * .12], [x + s * .45, y - s * .1], [x + s, y - s * k], 6), { w: 1.2, color, alpha, seed: seed + 3, amp: .15, t0: 1, t1: 2 });
}
function ridge(E, y0, amp, seed, k = 2.2, step) {
  const nz = fbm(seed, 3), pts = [];
  step = step || (E.phone ? 10 : 14);
  for (let x = -30; x <= E.W + 30; x += step) pts.push([x, y0 + nz(x / E.W * k * (E.phone ? .75 : 1)) * amp]);
  return pts;
}
function band(edge, bottom) { return edge.concat([[edge[edge.length - 1][0], bottom], [edge[0][0], bottom]]); }
function yAt(pts, x) { // y of a left-to-right polyline at x
  for (let i = 1; i < pts.length; i++) if (pts[i][0] >= x) { const a = pts[i - 1], b = pts[i], t = (x - a[0]) / ((b[0] - a[0]) || 1); return lerp(a[1], b[1], t); }
  return pts[pts.length - 1][1];
}
function tree(ctx, x, y, s, E, o = {}) {
  const pal = E.pal, r = rng(o.seed || 9), kind = o.kind == null ? (r() * 3 | 0) : o.kind;
  const trunkH = s * (kind === 2 ? .55 : .9);
  const cy = y - trunkH - s * (kind === 2 ? 1.05 : .78);
  let pts;
  if (kind === 2) pts = blobPts(x, cy, s * .52, o.seed || 9, 26, .06, 2.0);
  else if (kind === 1) { pts = cloudOutline(x - s, cy + s * .55, s * 2, r).pts; }
  else pts = blobPts(x, cy, s * .82, o.seed || 9, 28, .09);
  ctx.fillStyle = rgba(o.fill || pal.tree, o.fillAlpha == null ? .9 : o.fillAlpha);
  ctx.fill(poly(shift(pts, s * .12, s * .09)));
  ink(ctx, [[x, y], [x + (r() - .5) * 2, y - trunkH - s * .3]], { w: 1.5 * E.lw, color: pal.ink, alpha: o.alpha || .7, seed: (o.seed || 9) + 4, amp: .3, t0: 2, t1: 6 });
  ink(ctx, pts, { w: 1.3 * E.lw, color: pal.ink, alpha: o.alpha || .7, seed: (o.seed || 9) + 5, closed: true, amp: .5 });
  // a few leaf ticks inside
  for (let i = 0; i < 3; i++) {
    const a = r() * TAU, d = s * .35 * r(), px = x + Math.cos(a) * d, py = cy + Math.sin(a) * d * (kind === 2 ? 1.8 : 1);
    ink(ctx, quad([px - 3, py], [px, py - 2.5], [px + 3, py], 5), { w: .9, color: pal.ink, alpha: (o.alpha || .7) * .45, seed: i + 30, amp: .2, t0: 1, t1: 1 });
  }
}
function flower(ctx, x, y, s, color, E, seed) {
  const pal = E.pal, r = rng(seed);
  const top = [x + (r() - .5) * s, y - s * (2.2 + r())];
  ink(ctx, quad([x, y], [x + (r() - .5) * s * 1.5, (y + top[1]) / 2], top, 10), { w: 1.1 * E.lw, color: pal.ink, alpha: .55, seed, amp: .3, t0: 3, t1: 2 });
  ctx.fillStyle = rgba(color, E.dark ? .7 : .78);
  ctx.fill(poly(blobPts(top[0] + s * .18, top[1] + s * .12, s * .82, seed + 2, 18, .2)));
  const a0 = r() * TAU;
  for (let k = 0; k < 5; k++) {
    const a = a0 + k * TAU / 5, px = top[0] + Math.cos(a) * s * .55, py = top[1] + Math.sin(a) * s * .55;
    const pet = rotPts(circlePts(px, py, s * .42, 12, 0, .62), a, px, py);
    ink(ctx, pet, { w: .9 * E.lw, color: pal.ink, alpha: .55, seed: seed + 10 + k, closed: true, amp: .25, step: 1.6 });
  }
  ctx.fillStyle = rgba(pal.ink, .55); ctx.beginPath(); ctx.arc(top[0], top[1], s * .17, 0, TAU); ctx.fill();
}
function leaf(ctx, x, y, len, ang, E, o = {}) {
  // an almond leaf from (x,y) pointing along ang
  const w = len * (o.wide || .36), pts = [];
  for (let i = 0; i <= 12; i++) { const t = i / 12; pts.push([t * len, -Math.sin(Math.PI * t) * w * (t < .5 ? 1 : 1 - (t - .5) * .4)]); }
  for (let i = 11; i >= 1; i--) { const t = i / 12; pts.push([t * len, Math.sin(Math.PI * t) * w * .92]); }
  const c = Math.cos(ang), s = Math.sin(ang);
  const P = pts.map(([px, py]) => [x + px * c - py * s, y + px * s + py * c]);
  ctx.fillStyle = rgba(o.fill, o.fillAlpha == null ? .8 : o.fillAlpha);
  ctx.fill(poly(shift(P, o.dx == null ? 2 : o.dx, o.dy == null ? 1.6 : o.dy)));
  ink(ctx, P, { w: (o.w || 1.1) * E.lw, color: o.line || E.pal.ink, alpha: o.alpha || .7, seed: o.seed || 3, closed: true, amp: .3, step: 1.8 });
  ink(ctx, [[x + c * len * .08, y + s * len * .08], [x + c * len * .8, y + s * len * .8]], { w: .8 * E.lw, color: o.line || E.pal.ink, alpha: (o.alpha || .7) * .6, seed: (o.seed || 3) + 1, amp: .2, t0: 2, t1: 5 });
  return P;
}

// ------------------------------------------------------------------ palettes
// Low-chroma pigments: every colour sits close to the paper it is painted on.
const P = {
  nohara: {
    day: { paper: '#f2ece0', ink: '#3e3830', hills: ['#d6dac5', '#c3cbaa', '#b2bd96'], tree: '#a9b690', bush: '#b9c39e', cloud: '#fbf8f2', flowers: ['#d39a80', '#dfb7ab', '#d8c083', '#b4abc6'], sun: '#e0c587', ui: { accent: '#985a41', chosen: '#cfd6bd' } },
    night: { paper: '#1f2729', ink: '#d8d0bc', hills: ['#2b3537', '#252f31', '#1e2729'], tree: '#33403b', bush: '#2c3834', moon: '#ece2c6', star: '#e2d39f', firefly: '#e2e8a8', flowers: ['#bca993', '#ad9c90', '#c4b58d', '#a8a3b4'], cloud: '#2a3436', ui: { accent: '#e2c48e', chosen: '#36433d' } }
  },
  kirigami: {
    night: { paper: '#262f47', ink: '#d9d6cf', bands: ['#2c3653', '#333e5f', '#3b4669'], sky: '#2e3958', rim: '#f2eee5', moon: '#ece3c7', star: '#e6d296', spark: '#d4d7de', house: '#1e263d', window: '#e3cd8e', plane: '#f1ede5', ui: { accent: '#e6cf96', chosen: '#3d4870' } },
    day: { paper: '#dfe5e4', ink: '#4f5658', bands: ['#c9d1ba', '#b9c3a7', '#aab697'], sky: '#e8ecea', rim: '#fbfaf6', sun: '#e3c58c', cloud: '#f8f6f1', wall: '#f1eadf', roofs: ['#c99079', '#9eb0bd', '#b8a27f', '#a6b294'], window: '#6b737a', plane: '#fbfaf6', ui: { accent: '#8a5440', chosen: '#c9d1ba' } }
  },
  shasen: {
    day: { paper: '#f2ecdf', ink: '#3e3830', stripe: '#d6e0e2', cloud: '#fbf8f2', ui: { accent: '#3f6475', chosen: '#d3dde0' } },
    sage: { paper: '#f0eddf', ink: '#3e3830', stripe: '#d9e1cc', cloud: '#fbf8f2', ui: { accent: '#4d6640', chosen: '#d6dec9' } },
    butter: { paper: '#f3ede0', ink: '#3e3830', stripe: '#ece2bb', cloud: '#fbf8f2', ui: { accent: '#7d5a24', chosen: '#e8deb6' } },
    blush: { paper: '#f3ece2', ink: '#3e3830', stripe: '#ebd9d1', cloud: '#fbf8f2', ui: { accent: '#8e4b45', chosen: '#e7d4cc' } },
    night: { paper: '#1e2538', ink: '#c9d3ea', stripe: '#232b40', cloud: '#2a3348', ui: { accent: '#b9c8ea', chosen: '#2f3a55' } }
  },
  tsuru: {
    day: { paper: '#f2eee4', ink: '#3f3a31', leaves: ['#a9b690', '#bcc6a2', '#9dad88'], flowers: ['#a9b0cf', '#d9b4c0', '#b9a9cc'], pot: '#c69378', ui: { accent: '#5d7046', chosen: '#cfd7bd' } },
    night: { paper: '#1e2522', ink: '#cdd1bb', leaves: ['#2f3c34', '#35443a', '#2b372f'], flowers: ['#9da6c8', '#c9a9b6', '#ada0c4'], pot: '#4a3a32', glow: '#dfe6a4', moon: '#e8dfc4', ui: { accent: '#d9cfa0', chosen: '#36453b' } }
  },
  suimon: {
    day: { paper: '#edf0ea', ink: '#4f6268', pad: '#b3c09c', pad2: '#c2cdab', lotus: '#e2bdb4', ginkgo: '#d8c07f', petal: '#e4c3b9', fish: '#c9d3d1', koi: '#dcc4b0', ui: { accent: '#3f6470', chosen: '#cdd9d5' } },
    night: { paper: '#1b232b', ink: '#d6d3c4', pad: '#2b3a36', pad2: '#2f3f3a', lotus: '#c7aaa6', ginkgo: '#b8a573', petal: '#bba9a2', fish: '#26303a', koi: '#3a3a3c', moon: '#ebe0c2', ui: { accent: '#e5d6aa', chosen: '#2d3a46' } }
  },
  machi: {
    day: { paper: '#f1e9d9', ink: '#3f382f', ground: '#e6dcc6', roofs: ['#c4866c', '#93a5b4', '#a3ae8c', '#c9a46e', '#b48f88'], wall: '#f8f3e9', wall2: '#ece4d4', tree: '#a5b38c', door: '#a2826a', glass: '#cdd7d6', cloud: '#fbf8f2', ui: { accent: '#97543d', chosen: '#e3d7bd' } },
    night: { paper: '#23221f', ink: '#d9d0bd', ground: '#2a2925', roofs: ['#4f3d36', '#38414b', '#3f4637', '#4c4334', '#463a3a'], wall: '#35332e', wall2: '#2e2c28', window: '#e8c982', tree: '#2e3631', door: '#2a2724', glass: '#1f1e1b', cloud: '#2e2d29', moon: '#ece2c6', star: '#e2d39f', ui: { accent: '#e8c982', chosen: '#3b3833' } }
  },
  yamanami: {
    day: { paper: '#f1ece2', ink: '#3f3a33', ridges: ['#dadcd5', '#c8cec8', '#b3bcb7', '#9eaaa6'], sun: '#d9ae9a', kasumi: '#f7f3ec', pine: '#7c8a7d', ui: { accent: '#7c4b3b', chosen: '#d8dcd6' } },
    night: { paper: '#1c2130', ink: '#d5d0c2', ridges: ['#2d3446', '#282e40', '#222838', '#1b202e'], moon: '#e8dec3', star: '#e0d3a6', kasumi: '#2a3144', pine: '#151a25', ui: { accent: '#e4d3a4', chosen: '#2d3448' } }
  }
};

// ------------------------------------------------------------------ shared scene pieces
function dome(cx, base, w, h, seed, k) {
  const nz = fbm(seed, 2), pts = [];
  for (let i = 0; i <= 48; i++) { const t = i / 48, q = Math.max(0, 1 - Math.pow(2 * t - 1, 2)); pts.push([cx - w / 2 + w * t, base - h * Math.pow(q, k || .7) + nz(t * 3.2) * h * .05]); }
  return pts;
}
function hill(ctx, top, bottom, color, E, o = {}) {
  const shape = poly(top.concat([[top[top.length - 1][0], bottom], [top[0][0], bottom]]));
  const fillShape = poly(shift(top, 0, o.drop == null ? 3 : o.drop).concat([[top[top.length - 1][0], bottom], [top[0][0], bottom]]));
  gouache(ctx, fillShape, color, { seed: o.seed || 1, texture: o.texture == null ? .45 : o.texture, light: mix(color, '#ffffff', E.dark ? .06 : .3), dark: mix(color, '#000000', E.dark ? .25 : .1) });
  if (o.hatch) {
    const b = bbox(top), from = o.hatchFrom == null ? .5 : o.hatchFrom, x0 = b.x + b.w * from, x1 = x0 + b.w * (o.hatchW || .5);
    const seg = top.filter(p => p[0] >= x0 && p[0] <= x1);
    if (seg.length > 3) {
      const D = (o.hatchDepth || 30) * E.u;
      const lower = seg.map((p, i) => { const t = i / (seg.length - 1); return [p[0], p[1] + 2 + D * Math.pow(Math.sin(Math.PI * t), .7)]; });
      const bandPts = seg.concat(lower.slice().reverse());
      ctx.save(); ctx.clip(shape);
      hatch(ctx, poly(bandPts), bbox(bandPts), o.hatchAngle || -1.2, o.hatchGap || 4.2, E.pal.ink, o.hatch, .7, (o.seed || 1) + 1);
      ctx.restore();
    }
  }
  if (o.line !== false) ink(ctx, top, { w: (o.w || 1.4) * E.lw, color: E.pal.ink, alpha: o.alpha == null ? .6 : o.alpha, seed: (o.seed || 1) + 2, amp: .5, t0: 8, t1: 8 });
  return shape;
}
function stipple(ctx, clip, box, n, color, alpha, seed) {
  const r = rng(seed), p = new Path2D();
  for (let i = 0; i < n; i++) { const x = box.x + r() * box.w, y = box.y + r() * box.h, s = .5 + r() * 1; p.moveTo(x + s, y); p.ellipse(x, y, s, s * .8, r() * 3, 0, TAU); }
  ctx.save(); ctx.clip(clip); ctx.fillStyle = rgba(color, alpha); ctx.fill(p); ctx.restore();
}
function topAt(lines, x) { let y = Infinity; for (const L of lines) if (x >= L[0][0] && x <= L[L.length - 1][0]) y = Math.min(y, yAt(L, x)); return y; }
function driftCloud(dyn, E, x, y, w, seed, speed, draw) {
  // the sprite's baseline sits at w*.7+12 from its top; (x, y) is the cloud's bottom-left
  const spr = sprite(w + 30, w * .8 + 28, E.dpr, g => (draw || ((gg) => drawCloud(gg, 8, w * .7 + 12, w, E, { seed }))) (g));
  dyn.push({ draw(g, t) { let px = x - 8 + t * speed; px = ((px + spr.cssW) % (E.W + spr.cssW * 2)) - spr.cssW; if (!t) px = x - 8; g.drawImage(spr, px, y - w * .7 - 12, spr.cssW, spr.cssH); } });
}
function moonSprite(E, mr, color, seed, cut = .5) {
  return sprite(mr * 2 + 20, mr * 2 + 20, E.dpr, g => {
    const c = mr + 10;
    gouache(g, poly(blobPts(c, c, mr, seed, 40, .02)), color, { seed: seed + 1, texture: .6, angle: .9 });
    g.globalCompositeOperation = 'destination-out'; g.fillStyle = '#000';
    g.fill(poly(blobPts(c + mr * cut, c - mr * .26, mr * .9, seed + 2, 40, .02)));
  });
}
function starField(dyn, E, n, region, color, sparkColor, seed, opts = {}) {
  const r = rng(seed), stars = [];
  for (let i = 0; i < n; i++) {
    let x = r() * E.W, y = region[0] * E.H + r() * (region[1] - region[0]) * E.H;
    if (!E.phone && x > E.W * .24 && x < E.W * .76 && y > E.H * .14) y = E.H * (.03 + r() * .11);
    if (E.phone && y > E.H * .2 && x > E.W * .15 && x < E.W * .85) x = r() < .5 ? r() * E.W * .15 : E.W * (.85 + r() * .15);
    stars.push([x, y, r() < (opts.share || .3) ? 2 : r() < .5 ? 1 : 0, r() * TAU, (opts.size || 3.4) * (.7 + r() * .6) * E.u]);
  }
  dyn.push({ draw(g, t) {
    stars.forEach((s, i) => {
      const tw = t ? .55 + .45 * Math.sin(t * (.5 + (i % 5) * .2) + s[3]) : .9;
      if (s[2] === 2) { g.fillStyle = rgba(color, .85 * tw); g.fill(poly(spline(star5(s[0], s[1], s[4], s[3]), true, 3))); }
      else if (s[2] === 1) sparkle(g, s[0], s[1], s[4] * .9, sparkColor || color, .6 * tw, seed + i);
      else { g.fillStyle = rgba(color, .55 * tw); g.beginPath(); g.arc(s[0], s[1], .9, 0, TAU); g.fill(); }
    });
  } });
}

// ------------------------------------------------------------------ scenes
// Every scene keeps the middle of the screen quiet: drawings live along the
// bottom, in the top corners and at the edges, where they never sit under text.
const SCENES = {};

// 野原 Meadow --------------------------------------------------------------
function fenceOn(ctx, line, x0, x1, E, seed, alpha) {
  const posts = [];
  for (let x = x0; x <= x1; x += 13 * E.u) posts.push([x, yAt(line, x) + 6 * E.u]);
  posts.forEach((p, i) => ink(ctx, [[p[0], p[1]], [p[0] + .4, p[1] - 17 * E.u]], { w: 1.6 * E.lw, color: E.pal.ink, alpha, seed: seed + i, amp: .15, t0: 0, t1: 2 }));
  ink(ctx, posts.map(p => [p[0], p[1] - 6 * E.u]), { w: 1.2 * E.lw, color: E.pal.ink, alpha: alpha * .85, seed: seed + 90, amp: .4, t0: 2, t1: 2, smooth: 4 });
  ink(ctx, posts.map(p => [p[0], p[1] - 13 * E.u]), { w: 1.2 * E.lw, color: E.pal.ink, alpha: alpha * .85, seed: seed + 91, amp: .4, t0: 2, t1: 2, smooth: 4 });
}
SCENES.nohara = {
  zh: '野原', en: 'Meadow', variants: { day: '春の野 Spring field', night: '蛍 Fireflies' },
  draw(ctx, E, dyn) {
    const { W, H, pal, r, u } = E, night = E.dark, ph = E.phone;
    const la = night ? .4 : .62;
    if (night) glow(ctx, W * (ph ? .78 : .86), H * .1, W * .45, pal.moon, .045);
    // far hills: separate bumps, taller at the sides
    const g0 = H * (ph ? .875 : .8);
    const far = ph ? [[.08, .62, .075], [.5, .5, .03], [.92, .6, .085]] : [[.06, .4, .14], [.33, .3, .055], [.62, .27, .045], [.9, .42, .16]];
    const farTops = far.map(([cx, w, h], i) => dome(W * cx, g0, W * w, H * h, E.seed + 10 + i, .75));
    hill(ctx, ridge(E, g0 - 2, 4 * u, E.seed + 9, 1.5), H + 10, pal.hills[0], E, { seed: 29, alpha: la * .6, w: 1.1 });
    farTops.forEach((t, i) => hill(ctx, t, H + 10, pal.hills[0], E, { seed: 30 + i, hatch: night ? .1 : .16, hatchFrom: i < far.length / 2 ? .5 : .05, hatchW: .45, hatchDepth: 24, alpha: la * .8, w: 1.2 }));
    // trees standing on the far hills at the sides
    const treeSpots = ph ? [[.05, 13], [.13, 10], [.86, 12], [.95, 14]] : [[.03, 16], [.09, 20], [.14, 14], [.84, 18], [.9, 22], [.96, 15], [.36, 12]];
    treeSpots.forEach(([x, s], i) => { const px = W * x; tree(ctx, px, topAt(farTops, px) + 4, s * u, E, { seed: 50 + i, kind: i % 3, alpha: la }); });
    // big hills sweeping in from both edges
    const mid = ph ? [[-.12, .95, .1, .975], [1.14, 1.0, .115, .98]] : [[-.08, .66, .2, .97], [1.08, .7, .23, .975]];
    const midTops = mid.map(([cx, w, h, b], i) => dome(W * cx, H * b, W * w, H * h, E.seed + 20 + i, .65));
    midTops.forEach((t, i) => hill(ctx, t, H + 10, pal.hills[1], E, { seed: 60 + i, hatch: night ? .11 : .17, hatchFrom: i ? .12 : .55, hatchW: .38, hatchDepth: 34, alpha: la, w: 1.5 }));
    // a fence on the left hill, a big tree on the right one
    if (!ph) fenceOn(ctx, midTops[0], W * .07, W * .17, E, 300, la * .9);
    const bigX = W * (ph ? .86 : .9);
    tree(ctx, bigX, yAt(midTops[1], bigX) + 5, (ph ? 24 : 34) * u, E, { seed: 70, kind: 0, alpha: la });
    // bushes at the feet of the hills
    const bushes = ph ? [[.3, 9], [.62, 8]] : [[.22, 14], [.27, 10], [.7, 12], [.74, 9]];
    bushes.forEach(([x, s], i) => {
      const bx = W * x, by = H * (ph ? .93 : .905);
      const o = cloudOutline(bx - s * u * 1.6, by, s * u * 3.2, rng(80 + i));
      ctx.fillStyle = rgba(pal.bush, night ? .95 : .9); ctx.fill(poly(shift(o.pts, 2.5, 2)));
      ink(ctx, o.pts, { w: 1.2 * E.lw, color: pal.ink, alpha: la * .85, seed: 85 + i, closed: true, amp: .4 });
    });
    // the front meadow
    const front = ridge(E, H * (ph ? .962 : .955), 5 * u, E.seed + 31, 2);
    const fShape = hill(ctx, front, H + 10, pal.hills[2], E, { seed: 90, alpha: la * .9, w: 1.4 });
    stipple(ctx, fShape, { x: 0, y: H * .9, w: W, h: H * .1 }, ph ? 160 : 520, pal.ink, night ? .16 : .2, 91);
    // a dotted footpath climbing the left hill
    const fx = W * (ph ? .3 : .24);
    const path = spline([[fx, H + 6], [fx - 30 * u, H * (ph ? .955 : .94)], [fx - 4 * u, H * (ph ? .935 : .9)], [W * (ph ? .14 : .175), yAt(midTops[0], W * (ph ? .14 : .175)) + 8]], false, 14);
    resample(path, 10 * u).forEach((p, i, a) => { const k = 1 - i / a.length * .5; ctx.fillStyle = rgba(pal.ink, (night ? .3 : .45) * k); ctx.beginPath(); ctx.ellipse(p[0], p[1], 2.2 * k * u, 1.3 * k * u, .2, 0, TAU); ctx.fill(); });
    // grass and flowers
    const lines = [...midTops, front];
    const ng = Math.round((ph ? 30 : 80) * E.density);
    for (let i = 0; i < ng; i++) {
      const x = r() * W, top = Math.min(topAt(midTops, x), yAt(front, x));
      const y = top + 3 + r() * (H - top) * .5;
      if (y > H - 3) continue;
      tuft(ctx, x, y, (9 + r() * 10) * u, pal.ink, night ? .32 : .5, r, 1.2);
    }
    const nf = Math.round((ph ? 8 : 18) * E.density);
    for (let i = 0; i < nf; i++) {
      const side = ph ? r() : (i % 2 ? r() * .36 : .64 + r() * .36);
      const x = W * side, top = Math.min(topAt(midTops, x), yAt(front, x)), y = top + 10 + r() * (H - top) * .55;
      if (y > H - 6) continue;
      flower(ctx, x, y, (6 + r() * 3.5) * u, pal.flowers[i % pal.flowers.length], E, 100 + i);
    }
    void lines;
    if (!night) {
      // sun with rays
      const sx = W * (ph ? .84 : .87), sy = H * (ph ? .075 : .12), sr = (ph ? 24 : 34) * u;
      ctx.fillStyle = rgba(pal.sun, .55); ctx.fill(poly(blobPts(sx + 4, sy + 3, sr, 7, 26, .05)));
      ink(ctx, circlePts(sx, sy, sr, 32), { w: 1.5 * E.lw, color: mix(pal.sun, pal.ink, .5), alpha: .8, seed: 71, closed: true, amp: .5, sketch: true });
      for (let k = 0; k < 12; k++) {
        const a = k * TAU / 12 + .2, r0 = sr * 1.32, r1 = sr * (k % 2 ? 1.6 : 1.85);
        ink(ctx, [[sx + Math.cos(a) * r0, sy + Math.sin(a) * r0], [sx + Math.cos(a) * r1, sy + Math.sin(a) * r1]], { w: 1.4, color: mix(pal.sun, pal.ink, .5), alpha: .7, seed: 72 + k, amp: .2, t0: 2, t1: 2 });
      }
      const clouds = ph ? [[W * .3, H * .05, W * .4, 2.4]] : [[W * .05, H * .15, W * .15, 3], [W * .58, H * .1, W * .1, 4.2], [W * .3, H * .22, W * .08, 2.2]];
      clouds.forEach((c, i) => driftCloud(dyn, E, c[0], c[1], c[2], 110 + i, c[3]));
      const bx = W * (ph ? .14 : .72), by = H * (ph ? .045 : .1);
      [[0, 0, 6], [18, 7, 5], [9, -10, 4.4]].forEach(([dx, dy, s], i) => dyn.push({ draw(g, t) { bird(g, bx + dx * u + t * 1.4, by + dy * u - Math.sin(t * .3 + i) * 2, s * u, pal.ink, .6, 120 + i, t ? (Math.sin(t * 4 + i * 1.7) + 1) / 2 : .3); } }));
    } else {
      const mx = W * (ph ? .8 : .86), my = H * (ph ? .08 : .12), mr = (ph ? 22 : 30) * u;
      const moon = moonSprite(E, mr, pal.moon, 3);
      ctx.drawImage(moon, mx - mr - 10, my - mr - 10, moon.cssW, moon.cssH);
      starField(dyn, E, Math.round((ph ? 24 : 54) * E.density), [.02, ph ? .3 : .55], pal.star, pal.star, 140);
      const nfly = Math.round((ph ? 12 : 26) * E.density), flies = [];
      for (let i = 0; i < nfly; i++) { const x = r() * W, top = Math.min(topAt(midTops, x), yAt(front, x)); flies.push([x, top - 40 * u + r() * (H - top + 30 * u), r() * TAU, 8 + r() * 16]); }
      dyn.push({ draw(g, t) {
        flies.forEach(f => {
          const x = f[0] + Math.sin(t * .25 + f[2]) * f[3] * 1.6, y = f[1] + Math.cos(t * .21 + f[2] * 1.3) * f[3];
          const a = t ? .3 + .7 * Math.max(0, Math.sin(t * .9 + f[2] * 3)) : .55 + .45 * Math.sin(f[2] * 5);
          glow(g, x, y, 16 * u, pal.firefly, .3 * a);
          g.fillStyle = rgba(pal.firefly, .95 * a); g.beginPath(); g.arc(x, y, 1.6, 0, TAU); g.fill();
        });
      } });
    }
  }
};

// 切り紙 Torn paper ----------------------------------------------------------
function tornEdge(base, seed, o) {
  const lo = fbm(seed, 3), hi = noise1(seed + 5), r = rng(seed + 9), S = arclen(base);
  return base.map((p, i) => [p[0], p[1] + lo(S[i] * (o.lf || .011)) * (o.amp || 7) + hi(S[i] * .33) * (o.jag || 1.3) + (r() - .5) * (o.fuzz || .9)]);
}
function tornBand(ctx, edge, bottom, color, E, o = {}) {
  const seed = o.seed || 1, base = resample(edge, 2.2);
  const top = tornEdge(base, seed, { amp: o.amp, jag: o.jag });
  const rn = fbm(seed + 3, 2), fz = rng(seed + 4), S = arclen(top);
  const rim = top.map((p, i) => { const w = Math.max(0, (o.rim || 4) * (.15 + 1.05 * (rn(S[i] * .018) * .5 + .5)) + (fz() - .5) * 1.8); return [p[0], p[1] - w]; });
  const shape = e => poly(e.concat([[e[e.length - 1][0] + 60, bottom], [e[0][0] - 60, bottom]]));
  ctx.save();
  ctx.shadowColor = rgba('#000000', o.shadow == null ? .25 : o.shadow); ctx.shadowBlur = o.blur == null ? 9 : o.blur; ctx.shadowOffsetY = -1;
  ctx.fillStyle = rgba(o.rimColor || E.pal.rim, o.rimAlpha == null ? .95 : o.rimAlpha); ctx.fill(shape(rim));
  ctx.restore();
  const body = shape(top);
  gouache(ctx, body, color, { seed: seed + 6, texture: o.texture == null ? .9 : o.texture });
  return { top, body };
}
function tornShape(ctx, pts, color, E, o = {}) {
  const seed = o.seed || 1, Pp = resampleClosed(pts, 2);
  const nz = fbm(seed, 2), hi = noise1(seed + 1), r = rng(seed + 2), N = normals(Pp, true), S = arclen(Pp);
  const face = Pp.map((p, i) => { const d = nz(S[i] * .03) * (o.amp || 2.5) + hi(S[i] * .4) * .9 + (r() - .5) * .6; return [p[0] + N[i][0] * d, p[1] + N[i][1] * d]; });
  // the white rim sits on the outside of the piece, whichever way the outline runs
  let area = 0; for (let i = 0; i < Pp.length; i++) { const a = Pp[i], b = Pp[(i + 1) % Pp.length]; area += a[0] * b[1] - b[0] * a[1]; }
  const sgn = area > 0 ? -1 : 1;
  const rim = face.map((p, i) => { const w = Math.max(0, (o.rim || 3) * (nz(S[i] * .02 + 9) * .5 + .55)) + r() * .9; return [p[0] + sgn * N[i][0] * w, p[1] + sgn * N[i][1] * w]; });
  ctx.save(); ctx.shadowColor = rgba('#000000', o.shadow == null ? .18 : o.shadow); ctx.shadowBlur = 7; ctx.shadowOffsetY = 2;
  ctx.fillStyle = rgba(o.rimColor || E.pal.rim, .95); ctx.fill(poly(rim)); ctx.restore();
  gouache(ctx, poly(face), color, { seed: seed + 3, texture: o.texture == null ? .85 : o.texture, angle: o.angle });
  return face;
}
function paperPlane(ctx, x, y, s, ang, E, alpha = 1) {
  const pal = E.pal;
  const pts = [[0, 0], [-s * 1.25, -s * .42], [-s * .82, 0], [-s * 1.25, s * .5]];
  const Pp = rotPts(pts.map(([a, b]) => [x + a, y + b]), ang, x, y);
  ctx.save(); ctx.globalAlpha = alpha;
  ctx.shadowColor = rgba('#000000', .18); ctx.shadowBlur = 5; ctx.shadowOffsetY = 2;
  ctx.fillStyle = rgba(pal.plane, .98); ctx.fill(poly([Pp[0], Pp[1], Pp[2]]));
  ctx.shadowColor = 'transparent';
  ctx.fillStyle = rgba(mix(pal.plane, '#7d8590', .28), .98); ctx.fill(poly([Pp[0], Pp[2], Pp[3]]));
  ink(ctx, [Pp[0], Pp[2]], { w: .8, color: mix(pal.plane, '#59606b', .5), alpha: .7, seed: 3, amp: .1, t0: 1, t1: 1 });
  ctx.restore();
}
function scribbles(ctx, clip, box, color, alpha, seed, gap = 9) {
  // rows of tiny handwriting, too small to read: the texture of a used sheet
  const r = rng(seed), p = new Path2D();
  for (let y = box.y + 4; y < box.y + box.h; y += gap) {
    let x = box.x - r() * 30;
    while (x < box.x + box.w) {
      const word = 8 + r() * 26; p.moveTo(x, y);
      for (let k = 0; k < word; k += 1.6) p.lineTo(x + k, y + Math.sin(k * 1.9 + r()) * 1.6 - (r() < .08 ? 2.5 : 0));
      x += word + 4 + r() * 6;
    }
  }
  ctx.save(); ctx.clip(clip); ctx.strokeStyle = rgba(color, alpha); ctx.lineWidth = .55; ctx.lineJoin = 'round'; ctx.stroke(p); ctx.restore();
}
SCENES.kirigami = {
  zh: '切り紙', en: 'Torn paper', variants: { night: '紙の夜 Paper night', day: '紙の朝 Paper morning' },
  draw(ctx, E, dyn) {
    const { W, H, pal, r, u } = E, night = E.dark, ph = E.phone;
    gouache(ctx, poly([[0, 0], [W, 0], [W, H], [0, H]]), pal.paper, { seed: 5, texture: night ? .55 : .5, light: mix(pal.paper, '#ffffff', night ? .08 : .3), dark: mix(pal.paper, '#000000', night ? .18 : .06) });
    // torn sky pieces in the two top corners
    const tl = ph ? [[-30, -30], [W * .68, -30], [W * .52, H * .024], [W * .3, H * .04], [W * .1, H * .048], [-30, H * .058]] : [[-30, -30], [W * .34, -30], [W * .3, H * .05], [W * .2, H * .1], [W * .09, H * .14], [-30, H * .2]];
    tornShape(ctx, spline(tl, true, 6).reverse(), pal.sky, E, { seed: 21, amp: 5, rim: 4, shadow: night ? .3 : .12, outward: 1 });
    // strata along the bottom
    const base = ph ? .72 : .73;
    const edges = [
      ridge(E, H * base, 24 * u, E.seed + 41, 1.6),
      ridge(E, H * (base + (ph ? .05 : .085)), 18 * u, E.seed + 42, 2.1),
      ridge(E, H * (base + (ph ? .095 : .165)), 12 * u, E.seed + 43, 2.6)
    ];
    edges.forEach((e, i) => {
      const b = tornBand(ctx, e, H + 10, pal.bands[i], E, { seed: 50 + i, rim: 4.4 - i * .5, amp: 8 - i * 1.5, shadow: night ? .3 : .12 });
      if (i === 1) scribbles(ctx, b.body, { x: 0, y: H * base, w: W, h: H * (1 - base) }, mix(pal.bands[i], night ? '#ffffff' : '#000000', night ? .35 : .25), night ? .22 : .2, 61);
    });
    // houses standing on the last strip
    const groups = ph ? [[.03, 5]] : [[.64, 6], [.02, 4]];
    const windows = [];
    groups.forEach(([gx, n], gi) => {
      let x = W * gx;
      for (let i = 0; i < n; i++) {
        const w = (ph ? 34 : 46 + r() * 22) * u, h = (ph ? 34 : 40) * u + r() * 34 * u, roof = (18 + r() * 14) * u;
        const gy = yAt(edges[2], x + w / 2) + 14 * u + r() * 6;
        const body = [[x, gy], [x, gy - h], [x + w / 2, gy - h - roof], [x + w, gy - h], [x + w, gy]];
        tornShape(ctx, body, night ? pal.house : pal.wall, E, { seed: 300 + gi * 20 + i, amp: .8, rim: night ? 1.6 : 2.2, shadow: night ? .35 : .15, texture: .6 });
        if (!night) tornShape(ctx, [[x - 4, gy - h + 3], [x + w / 2, gy - h - roof - 3], [x + w + 4, gy - h + 3]], pal.roofs[(i + gi) % pal.roofs.length], E, { seed: 340 + gi * 20 + i, amp: .7, rim: 1.6, shadow: .12 });
        const cols = w > 52 * u ? 2 : 1, rows = h > 54 * u ? 2 : 1;
        for (let a = 0; a < cols; a++) for (let b = 0; b < rows; b++) {
          const ww = 9 * u, wx = x + (cols === 1 ? w / 2 - ww / 2 : w * (.22 + a * .38)), wy = gy - h + 10 * u + b * 18 * u;
          if (night && r() < .2) continue;
          windows.push([wx, wy, ww, 400 + gi * 50 + i * 7 + a + b * 3]);
        }
        if (night && i === 2) {
          const cx = x + w / 2, cy = gy - h - roof + 3, k = u * 1.3;
          const cat = [[cx - 5 * k, cy], [cx - 5 * k, cy - 7 * k], [cx - 4 * k, cy - 11 * k], [cx - 2.4 * k, cy - 8.5 * k], [cx + 1 * k, cy - 8.5 * k], [cx + 2.6 * k, cy - 11 * k], [cx + 3.8 * k, cy - 7 * k], [cx + 4 * k, cy]];
          ctx.fillStyle = rgba('#161b2b', .97); ctx.fill(poly(spline(cat, true, 3)));
          ink(ctx, quad([cx + 4 * k, cy - 1], [cx + 11 * k, cy - 2], [cx + 10 * k, cy - 9 * k], 8), { w: 2.2 * k, color: '#161b2b', alpha: .97, seed: 77, amp: .3, t0: 1, t1: 3 });
        }
        x += w + (6 + r() * 12) * u;
      }
    });
    windows.forEach(([wx, wy, ww, sd]) => {
      if (night) glow(ctx, wx + ww / 2, wy + ww / 2, 16 * u, pal.window, .14);
      gouache(ctx, poly(blobPts(wx + ww / 2, wy + ww / 2, ww * .6, sd, 8, .06)), pal.window, { seed: sd % 50, texture: .5 });
    });
    if (night) {
      const mx = W * (ph ? .62 : .12), my = H * (ph ? .058 : .1), mr = (ph ? 20 : 40) * u;
      const moon = moonSprite(E, mr, pal.moon, 61, .52);
      ctx.save(); ctx.shadowColor = rgba('#000000', .3); ctx.shadowBlur = 8; ctx.shadowOffsetY = 2;
      ctx.drawImage(moon, mx - mr - 10, my - mr - 10, moon.cssW, moon.cssH); ctx.restore();
      starField(dyn, E, Math.round((ph ? 20 : 44) * E.density), [.04, base - .06], pal.star, pal.spark, 160, { share: .55, size: 4.4 });
    } else {
      const sx = W * (ph ? .64 : .87), sy = H * (ph ? .058 : .2), sr = (ph ? 21 : 44) * u;
      tornShape(ctx, circlePts(sx, sy, sr, 40), pal.sun, E, { seed: 81, amp: 1.6, rim: 3.2, shadow: .14, angle: .7 });
      const clouds = ph ? [[W * .52, H * .69, W * .32, 2.6]] : [[W * .04, H * .34, W * .16, 2.4], [W * .72, H * .34, W * .14, 3.4]];
      clouds.forEach((c, i) => driftCloud(dyn, E, c[0], c[1], c[2], 0, c[3], g => {
        const o = cloudOutline(12, c[2] * .7 + 12, c[2], rng(200 + i));
        tornShape(g, o.pts.slice().reverse(), pal.cloud, E, { seed: 210 + i, amp: 1.2, rim: 2.4, shadow: .1, texture: .35 });
      }));
    }
    // a paper plane on its dashed path
    const pl = ph ? { a: [W * .06, H * .69], c: [W * .45, H * .62], b: [W * .86, H * .66] } : { a: [W * .48, H * .1], c: [W * .66, H * .02], b: [W * .9, H * .08] };
    const trail = quad(pl.a, pl.c, pl.b, 50);
    dyn.push({ draw(g, t) {
      const cyc = 26, k = t ? ((t % cyc) / cyc) : .64, n = Math.max(3, Math.floor(trail.length * k));
      const part = trail.slice(0, n), dashes = resample(part, 4.5);
      g.strokeStyle = rgba(night ? '#e8e4dc' : '#6f777a', night ? .45 : .5); g.lineWidth = 1.2; g.lineCap = 'round';
      for (let i = 0; i + 1 < dashes.length; i += 2) { g.beginPath(); g.moveTo(dashes[i][0], dashes[i][1]); g.lineTo(dashes[i + 1][0], dashes[i + 1][1]); g.stroke(); }
      const p = part[part.length - 1], q = part[Math.max(0, part.length - 3)];
      paperPlane(g, p[0], p[1], 17 * u, Math.atan2(p[1] - q[1], p[0] - q[0]), E, t ? Math.min(1, (1 - k) * 8, k * 12) : 1);
    } });
  }
};

// 斜線 Stripes / 設計図 Blueprint -------------------------------------------
SCENES.shasen = {
  zh: '斜線', en: 'Stripes', variants: { day: '空 Sky stripes', sage: '若草 Sage stripes', butter: '菜の花 Butter stripes', blush: '桜 Blush stripes', night: '設計図 Blueprint' },
  draw(ctx, E, dyn) {
    const { W, H, pal, u } = E, ph = E.phone;
    if (E.variant === 'night') return blueprint(ctx, E, dyn);
    const ang = -Math.PI * .22, dx = Math.cos(ang), dy = Math.sin(ang), nx = -dy, ny = dx;
    const sw = (ph ? 46 : 64) * u, R = Math.hypot(W, H);
    const tile = crayonTile(mix(pal.stripe, '#ffffff', .4), 7, { angle: 0, count: 520, alpha: [.05, .24] });
    const tileD = crayonTile(mix(pal.stripe, '#5b5e60', .22), 8, { angle: 0, count: 260, alpha: [.03, .12] });
    let k = 0;
    for (let d = -R; d < R; d += sw * 2, k++) {
      const cx = W / 2 + nx * d, cy = H / 2 + ny * d, edgeA = [], edgeB = [];
      const nA = fbm(500 + k, 2), nB = fbm(600 + k, 2);
      for (let s = -R * .7; s <= R * .7; s += 12) {
        edgeA.push([cx + dx * s + nx * (nA(s * .008) * 3.4), cy + dy * s + ny * (nA(s * .008) * 3.4)]);
        edgeB.push([cx + dx * s + nx * (sw + nB(s * .008) * 3.4), cy + dy * s + ny * (sw + nB(s * .008) * 3.4)]);
      }
      const shape = poly(edgeA.concat(edgeB.reverse()));
      ctx.save();
      ctx.fillStyle = rgba(pal.stripe, .9); ctx.fill(shape);
      ctx.clip(shape);
      ctx.fillStyle = pattern(ctx, tile, ang, k * 37, 0); ctx.fill(shape);
      ctx.fillStyle = pattern(ctx, tileD, ang, k * 53, 9); ctx.fill(shape);
      ctx.restore();
    }
    const clouds = ph ? [[W * .5, H * .05, W * .42, 2.4], [W * .58, H * .87, W * .3, 3]] : [[W * .03, H * .16, W * .15, 2.6], [W * .78, H * .93, W * .15, 3.2], [W * .8, H * .13, W * .1, 4]];
    clouds.forEach((c, i) => driftCloud(dyn, E, c[0], c[1], c[2], 130 + i, c[3]));
    const sp = ph ? [[.06, .05], [.12, .8], [.93, .62]] : [[.24, .07], [.96, .38], [.04, .6], [.62, .96], [.42, .04]];
    sp.forEach(([x, y], i) => dyn.push({ draw(g, t) { sparkle(g, W * x, H * y, (6 + (i % 2) * 2.5) * u * (t ? .85 + .15 * Math.sin(t * 1.3 + i) : 1), pal.ink, .55, 140 + i); } }));
  }
};
function blueprint(ctx, E, dyn) {
  const { W, H, pal, u } = E, ph = E.phone, line = pal.ink;
  glow(ctx, W * .5, H * .45, Math.max(W, H) * .7, mix(pal.paper, '#ffffff', .08), .5);
  const g = ph ? 22 : 24, minor = new Path2D(), major = new Path2D(), nz = noise1(9);
  let i = 0;
  for (let x = (W % g) / 2; x <= W; x += g, i++) { const p = i % 5 ? minor : major; p.moveTo(x + nz(x) * .6, 0); p.quadraticCurveTo(x + nz(x + 50) * 1.4, H / 2, x + nz(x + 99) * .6, H); }
  i = 0;
  for (let y = (H % g) / 2; y <= H; y += g, i++) { const p = i % 5 ? minor : major; p.moveTo(0, y + nz(y + 7) * .6); p.quadraticCurveTo(W / 2, y + nz(y + 70) * 1.4, W, y + nz(y + 140) * .6); }
  ctx.lineWidth = .6; ctx.strokeStyle = rgba(line, .075); ctx.stroke(minor);
  ctx.lineWidth = .8; ctx.strokeStyle = rgba(line, .15); ctx.stroke(major);
  // a large compass ring cutting the top-right corner
  const cx = W * (ph ? 1.0 : .96), cy = H * (ph ? 0 : .04), R = (ph ? 160 : 270) * u;
  ink(ctx, circlePts(cx, cy, R, 140), { w: 1.2, color: line, alpha: .42, seed: 1, closed: true, amp: .4, step: 3, sketch: .3 });
  ink(ctx, circlePts(cx, cy, R * .8, 120), { w: .9, color: line, alpha: .24, seed: 2, closed: true, amp: .4, step: 3 });
  ink(ctx, circlePts(cx, cy, R * .3, 60), { w: .9, color: line, alpha: .3, seed: 3, closed: true, amp: .3, step: 3 });
  const ticks = new Path2D();
  for (let k = 0; k < 144; k++) { const a = k * TAU / 144, l = k % 6 ? 6 : 13; ticks.moveTo(cx + Math.cos(a) * R, cy + Math.sin(a) * R); ticks.lineTo(cx + Math.cos(a) * (R - l), cy + Math.sin(a) * (R - l)); }
  ctx.strokeStyle = rgba(line, .36); ctx.lineWidth = .9; ctx.stroke(ticks);
  // construction circles and lines bottom-left
  const bx = W * (ph ? .06 : .08), by = H * (ph ? .9 : .84), br = (ph ? 74 : 120) * u;
  const dash = resampleClosed(circlePts(bx, by, br, 100), 3.2);
  const dp = new Path2D(); for (let k = 0; k + 1 < dash.length; k += 4) { dp.moveTo(dash[k][0], dash[k][1]); dp.lineTo(dash[k + 1][0], dash[k + 1][1]); }
  ctx.strokeStyle = rgba(line, .42); ctx.lineWidth = 1.1; ctx.stroke(dp);
  ink(ctx, circlePts(bx, by, br * .55, 70), { w: 1, color: line, alpha: .32, seed: 7, closed: true, amp: .4, step: 3 });
  ink(ctx, [[bx - br * 1.4, by - br * .6], [bx + br * 2.4, by + br * .35]], { w: .9, color: line, alpha: .3, seed: 5, amp: .3, t0: 0, t1: 30 });
  ink(ctx, [[bx + br * .4, by - br * 2], [bx - br * .15, by + br * 1.4]], { w: .9, color: line, alpha: .3, seed: 6, amp: .3, t0: 30, t1: 0 });
  ctx.fillStyle = rgba(line, .6); ctx.beginPath(); ctx.arc(bx, by, 2.4, 0, TAU); ctx.fill();
  // a dimension line with arrow heads along the left
  const lx = W * (ph ? .05 : .03), ly0 = H * (ph ? .3 : .26), ly1 = H * (ph ? .6 : .62);
  ink(ctx, [[lx, ly0], [lx, ly1]], { w: .9, color: line, alpha: .34, seed: 8, amp: .2, t0: 0, t1: 0 });
  [[ly0, 1], [ly1, -1]].forEach(([y, s], k) => { ink(ctx, [[lx - 4, y + s * 8], [lx, y], [lx + 4, y + s * 8]], { w: .9, color: line, alpha: .38, seed: 9 + k, amp: .1, t0: 0, t1: 0 }); ink(ctx, [[lx - 9, y], [lx + 9, y]], { w: .8, color: line, alpha: .3, seed: 11 + k, amp: .1, t0: 0, t1: 0 }); });
  // a ruler along the bottom edge
  const ruler = new Path2D(), y0 = H - 6;
  for (let x = W * (ph ? .3 : .32), k = 0; x < W * (ph ? .95 : .72); x += 6, k++) { const l = k % 10 ? (k % 5 ? 5 : 8) : 13; ruler.moveTo(x, y0); ruler.lineTo(x, y0 - l); }
  ctx.strokeStyle = rgba(line, .34); ctx.lineWidth = .9; ctx.stroke(ruler);
  // honeycomb fading out in a lower corner
  const hx = W * (ph ? .82 : .88), hy = H * (ph ? .76 : .72), hs = 14 * u;
  const hp = new Path2D();
  for (let a = -6; a <= 6; a++) for (let b = -5; b <= 5; b++) {
    const x = hx + a * hs * 1.75 + (b % 2 ? hs * .87 : 0), y = hy + b * hs * 1.5, d = Math.hypot(x - hx, y - hy) / (hs * 9);
    if (d > 1) continue;
    for (let k = 0; k <= 6; k++) { const an = Math.PI / 6 + k * TAU / 6, px = x + Math.cos(an) * hs * .9, py = y + Math.sin(an) * hs * .9; if (k) hp.lineTo(px, py); else hp.moveTo(px, py); }
  }
  ctx.save(); const mask = ctx.createRadialGradient(hx, hy, 0, hx, hy, hs * 9); mask.addColorStop(0, rgba(line, .3)); mask.addColorStop(1, rgba(line, 0));
  ctx.strokeStyle = mask; ctx.lineWidth = .9; ctx.stroke(hp); ctx.restore();
  // + marks
  const marks = ph ? [[.1, .1], [.88, .55], [.2, .66], [.6, .97]] : [[.04, .1], [.36, .05], [.7, .94], [.97, .6], [.5, .97], [.2, .9]];
  marks.forEach(([x, y], k) => dyn.push({ draw(g2, t) { sparkle(g2, W * x, H * y, 5 * u, line, .55 * (t ? .7 + .3 * Math.sin(t + k) : 1), 200 + k); } }));
  dyn.push({ draw(g2, t) {
    const a = Math.PI * .64 + (t ? Math.sin(t * .05) * .35 : 0);
    ink(g2, [[cx, cy], [cx + Math.cos(a) * R, cy + Math.sin(a) * R]], { w: 1, color: line, alpha: .5, seed: 300, amp: .2, t0: 0, t1: 4 });
    g2.fillStyle = rgba(line, .7); g2.beginPath(); g2.arc(cx + Math.cos(a) * R, cy + Math.sin(a) * R, 2.6, 0, TAU); g2.fill();
  } });
}

// 朝顔 Morning-glory vines ---------------------------------------------------
function growVine(start, dir, len, seed, o = {}) {
  const nz = fbm(seed, 2), pts = [start.slice()];
  let a = dir, x = start[0], y = start[1];
  for (let s = 0; s < len; s += 5) {
    a += nz(s * .006) * .05 + (o.curl || 0) * (s / len) * .025 + (o.pull != null ? Math.sin(o.pull - a) * .03 : 0);
    x += Math.cos(a) * 5; y += Math.sin(a) * 5; pts.push([x, y]);
  }
  return pts;
}
function heartLeaf(ctx, x, y, s, ang, E, o = {}) {
  // a heart-shaped leaf whose stalk joins at (x,y) and whose tip points along ang
  const pts = [];
  for (let i = 0; i < 36; i++) { const t = i / 36 * TAU, hx = 16 * Math.pow(Math.sin(t), 3), hy = 13 * Math.cos(t) - 5 * Math.cos(2 * t) - 2 * Math.cos(3 * t) - Math.cos(4 * t); pts.push([hx * .85, hy - (hy < -8 ? (hy + 8) * .35 : 0)]); }
  const k = s / 24, ca = Math.cos(ang), sa = Math.sin(ang);
  const P = pts.map(([lx, ly]) => { const along = (5 - ly) * k, side = lx * k; return [x + ca * along - sa * side, y + sa * along + ca * side]; });
  ctx.fillStyle = rgba(o.fill, o.fillAlpha == null ? .85 : o.fillAlpha);
  ctx.fill(poly(shift(P, (o.dx == null ? 2.4 : o.dx) * E.u, (o.dy == null ? 1.8 : o.dy) * E.u)));
  ink(ctx, P, { w: (o.w || 1.2) * E.lw, color: E.pal.ink, alpha: o.alpha, seed: o.seed || 3, closed: true, amp: .35, step: 1.8 });
  const tip = [x + ca * 23 * k, y + sa * 23 * k];
  ink(ctx, quad([x, y], [x + ca * 12 * k - sa * 1.5 * k, y + sa * 12 * k + ca * 1.5 * k], tip, 8), { w: .9 * E.lw, color: E.pal.ink, alpha: o.alpha * .6, seed: (o.seed || 3) + 1, amp: .15, t0: 2, t1: 6 });
  for (const sd of [-1, 1]) for (const f of [.3, .55]) {
    const bx = x + ca * 23 * k * f, by = y + sa * 23 * k * f, ex = bx + (ca * 5 - sa * sd * 8) * k, ey = by + (sa * 5 + ca * sd * 8) * k;
    ink(ctx, quad([bx, by], [bx - sa * sd * 5 * k, by + ca * sd * 5 * k], [ex, ey], 6), { w: .7 * E.lw, color: E.pal.ink, alpha: o.alpha * .4, seed: (o.seed || 3) + 5 + f * 10 + sd, amp: .1, t0: 1, t1: 3 });
  }
}
function asagao(ctx, x, y, s, ang, color, E, seed, alpha) {
  // a morning glory seen from the front: five soft lobes, a pale star, a throat
  const nz = noise1(seed), face = [];
  for (let i = 0; i < 40; i++) { const t = i / 40 * TAU; const rr = s * (1 + .07 * Math.cos(t * 5 + ang) + nz(i * .7) * .04); face.push([x + Math.cos(t) * rr, y + Math.sin(t) * rr * .92]); }
  ctx.fillStyle = rgba(color, E.dark ? .78 : .82); ctx.fill(poly(shift(face, 2 * E.u, 1.6 * E.u)));
  ctx.fillStyle = rgba(E.dark ? '#e9e4d6' : '#fbf8f2', E.dark ? .35 : .7); ctx.fill(poly(circlePts(x + 2 * E.u, y + 1.6 * E.u, s * .32, 16)));
  ink(ctx, face, { w: 1.1 * E.lw, color: E.pal.ink, alpha, seed, closed: true, amp: .3, step: 1.8 });
  for (let k = 0; k < 5; k++) { const a = ang + k * TAU / 5; ink(ctx, [[x + Math.cos(a) * s * .22, y + Math.sin(a) * s * .22], [x + Math.cos(a) * s * .92, y + Math.sin(a) * s * .86]], { w: .7, color: E.pal.ink, alpha: alpha * .4, seed: seed + k, amp: .1, t0: 1, t1: 4 }); }
  ctx.fillStyle = rgba(E.pal.ink, alpha * .6); ctx.beginPath(); ctx.arc(x, y, s * .1, 0, TAU); ctx.fill();
}
function bud(ctx, x, y, s, ang, color, E, seed, alpha) {
  const pts = []; for (let i = 0; i < 20; i++) { const t = i / 20 * TAU; pts.push([Math.cos(t) * s, Math.sin(t) * s * .32 * (1 - .4 * Math.cos(t))]); }
  const Pp = rotPts(pts.map(([a, b]) => [x + a + s, y + b]), ang, x, y);
  ctx.fillStyle = rgba(color, .8); ctx.fill(poly(shift(Pp, 1.4, 1.2)));
  ink(ctx, Pp, { w: .9 * E.lw, color: E.pal.ink, alpha, seed, closed: true, amp: .2, step: 1.4 });
  ink(ctx, rotPts([[x + s * .2, y - s * .2], [x + s * 1.7, y + s * .1]], ang, x, y), { w: .7, color: E.pal.ink, alpha: alpha * .5, seed: seed + 1, amp: .2, t0: 1, t1: 2 });
}
function tendril(ctx, x, y, a, s, E, seed, alpha) {
  const pts = [[x, y]];
  for (let i = 1; i < 44; i++) { const t = i / 43, rr = s * (1 - t * .82), ang = a + t * 10; pts.push([x + Math.cos(a) * s * t * 1.6 + Math.cos(ang) * rr * t, y + Math.sin(a) * s * t * 1.6 + Math.sin(ang) * rr * t]); }
  ink(ctx, pts, { w: .9 * E.lw, color: E.pal.ink, alpha, seed, amp: .1, t0: 2, t1: 8 });
}
function drawVine(ctx, pts, E, o) {
  const { pal } = E, r = rng(o.seed), u = E.u;
  ink(ctx, pts, { w: (o.w || 2.2) * E.lw, color: pal.ink, alpha: o.alpha, seed: o.seed, amp: .5, t0: 4, t1: 40, sketch: .22 });
  const S = arclen(pts), L = S[S.length - 1];
  let next = 14 + r() * 10, side = 1, idx = 0;
  for (let i = 1; i < pts.length; i++) {
    if (S[i] < next) continue;
    next += (o.gap || 30) * u * (.75 + r() * .5); side *= -1; idx++;
    const a = Math.atan2(pts[i][1] - pts[i - 1][1], pts[i][0] - pts[i - 1][0]), t = S[i] / L;
    const n = [-Math.sin(a) * side, Math.cos(a) * side];
    const stalk = 7 * u, bx = pts[i][0] + n[0] * stalk, by = pts[i][1] + n[1] * stalk;
    ink(ctx, [pts[i], [bx, by]], { w: .9 * E.lw, color: pal.ink, alpha: o.alpha * .8, seed: o.seed + idx, amp: .1, t0: 1, t1: 1 });
    const roll = r();
    if (roll < .12 && t > .15) { tendril(ctx, pts[i][0], pts[i][1], a + side * 1.2, 9 * u, E, o.seed + idx * 3, o.alpha * .8); continue; }
    if (o.flowers && roll > 1 - o.flowers && t > .2) {
      const fs = (o.flower || 13) * u * (.85 + r() * .3);
      const fx = bx + n[0] * fs * .9, fy = by + n[1] * fs * .9;
      if (r() < .3) bud(ctx, bx, by, fs * .8, Math.atan2(n[1], n[0]) - side * .4, pal.flowers[idx % pal.flowers.length], E, o.seed + idx * 5, o.alpha);
      else { if (E.dark) glow(ctx, fx, fy, fs * 2.2, pal.flowers[idx % pal.flowers.length], .1); asagao(ctx, fx, fy, fs, r() * TAU, pal.flowers[idx % pal.flowers.length], E, o.seed + idx * 5, o.alpha); }
      continue;
    }
    const len = (o.leaf || 26) * u * (1.1 - t * .45) * (.75 + r() * .5);
    heartLeaf(ctx, bx, by, len, Math.atan2(n[1], n[0]) + (r() - .5) * .9 + a * .0, E, { fill: pal.leaves[idx % pal.leaves.length], fillAlpha: E.dark ? .95 : .82, alpha: o.alpha, seed: o.seed + idx * 7 });
  }
}
SCENES.tsuru = {
  zh: '朝顔', en: 'Morning glory', variants: { day: '朝顔 Morning glory', night: '夜の温室 Night greenhouse' },
  draw(ctx, E, dyn) {
    const { W, H, pal, u } = E, night = E.dark, ph = E.phone, a = night ? .5 : .74;
    if (night) { glow(ctx, W * .14, H * .1, W * .45, pal.moon, .045); }
    // a climbing vine up the left edge that arches over the top-left corner
    const v1 = growVine([-8, H * 1.01], -Math.PI * .47, ph ? H * .3 : H * .84, 11, { curl: 1.6 });
    drawVine(ctx, v1, E, { seed: 11, alpha: a, flowers: .3, flower: 16, w: 2.4, leaf: ph ? 24 : 30 });
    // one running along the bottom from the left, one from the right corner
    const v2 = growVine([-8, H * (ph ? .9 : .93)], -Math.PI * .05, ph ? W * .55 : W * .3, 12, { curl: -.6 });
    drawVine(ctx, v2, E, { seed: 12, alpha: a, flowers: .32, flower: 15, w: 2, leaf: 24 });
    const v3 = growVine([W + 8, H * (ph ? .88 : .975)], Math.PI * 1.03, ph ? W * .5 : W * .34, 13, { curl: .8 });
    drawVine(ctx, v3, E, { seed: 13, alpha: a, flowers: .34, flower: 15, w: 2, leaf: 26 });
    if (ph) {
      const drape = growVine([W + 8, H * .02], Math.PI * 1.03, W * .62, 14, { curl: -.5 });
      drawVine(ctx, drape, E, { seed: 14, alpha: a, flowers: .3, flower: 12, w: 1.8, leaf: 18, gap: 26 });
    }
    // a hanging pot in the top-right corner; its strands sway (not on a phone: it would hang over the text)
    if (!ph) {
    const px = W * (ph ? .8 : .86), py = (ph ? 66 : 100) * u, pw = (ph ? 44 : 70) * u;
    const strands = [];
    const nS = ph ? 4 : 6;
    for (let k = 0; k < nS; k++) strands.push({ x: px - pw * .42 + k * pw * .84 / (nS - 1), len: H * (ph ? .14 + (k % 2) * .08 + k * .02 : .2 + (k % 2) * .14 + k * .04), seed: 20 + k });
    const potSpr = sprite(pw * 3, H * .72, E.dpr, g => {
      g.save(); g.translate(pw * 1.5 - px, 0);
      strands.forEach(s => {
        const pts = growVine([s.x, py + pw * .5], Math.PI / 2 + (s.x - px) / pw * .3, s.len, s.seed, { pull: Math.PI / 2 });
        drawVine(g, pts, E, { seed: s.seed, alpha: a, flowers: .22, flower: 12, w: 1.6, leaf: 21, gap: 24 });
      });
      ink(g, [[px, 0], [px - pw * .5, py]], { w: 1.1, color: pal.ink, alpha: a * .8, seed: 31, amp: .3, t0: 0, t1: 0 });
      ink(g, [[px, 0], [px + pw * .5, py]], { w: 1.1, color: pal.ink, alpha: a * .8, seed: 32, amp: .3, t0: 0, t1: 0 });
      const pot = [[px - pw * .56, py], [px + pw * .56, py], [px + pw * .4, py + pw * .72], [px - pw * .4, py + pw * .72]];
      g.fillStyle = rgba(pal.pot, night ? .95 : .82); g.fill(poly(shift(pot, 3, 2.4)));
      hatch(g, poly(pot), bbox(pot), -.8, 3.6, pal.ink, night ? .2 : .2, .7, 8);
      ink(g, pot, { w: 1.5 * E.lw, color: pal.ink, alpha: a, seed: 33, closed: true, amp: .4, sketch: true });
      ink(g, [[px - pw * .62, py + pw * .13], [px + pw * .62, py + pw * .13]], { w: 1.3, color: pal.ink, alpha: a * .85, seed: 34, amp: .3, t0: 2, t1: 2 });
      for (let k = 0; k < 5; k++) heartLeaf(g, px - pw * .36 + k * pw * .18, py + 2, 17 * u, -Math.PI / 2 + (k - 2) * .5, E, { fill: pal.leaves[k % 3], fillAlpha: .92, alpha: a, seed: 40 + k });
      g.restore();
    });
    dyn.push({ draw(g, t) {
      const sway = t ? Math.sin(t * .45) * .02 : 0;
      g.save(); g.translate(px, 0); g.rotate(sway); g.drawImage(potSpr, -pw * 1.5, 0, potSpr.cssW, potSpr.cssH); g.restore();
    } });
    }
    if (night) starField(dyn, E, Math.round((ph ? 10 : 22) * E.density), [.02, .4], pal.moon, pal.moon, 170, { share: .2, size: 2.6 });
    dyn.push({ motionOnly: true, draw(g, t) {
      for (let k = 0; k < 5; k++) {
        const T = (t * .018 + k * .21) % 1, x = (k % 2 ? px : W * .08) + Math.sin(T * 9 + k) * 30 - k * 12, y = (k % 2 ? py : H * .2) + T * H * .75;
        g.fillStyle = rgba(pal.flowers[k % pal.flowers.length], .65 * Math.sin(Math.PI * T));
        g.fill(poly(rotPts(circlePts(x, y, 4.5 * u, 10, 0, .55), T * 12 + k, x, y)));
      }
    } });
  }
};

// 蓮池 Lotus pond ---------------------------------------------------------------
const SQ = .52; // the pond is seen at an angle
function ripple(ctx, x, y, r0, rings, E, seed, alpha, o = {}) {
  const r = rng(seed), sq = o.squash || SQ;
  for (let k = 0; k < rings; k++) {
    const rad = r0 * Math.pow(1 + k * .6, 1.12), a = alpha * Math.pow(1 - k / (rings + .6), 1.25);
    const gap = .4 + r() * 1.1, start = r() * TAU, n = Math.max(30, rad * .8 | 0), pts = [];
    for (let i = 0; i <= n; i++) { const ang = start + (TAU - gap) * i / n; pts.push([x + Math.cos(ang) * rad, y + Math.sin(ang) * rad * sq]); }
    ink(ctx, pts, { w: (1.6 - k * .12) * E.lw, color: E.pal.ink, alpha: a, seed: seed + k * 13, amp: .5 + k * .12, freq: .02, t0: 12, t1: 16, step: 3 });
  }
}
function lotusPad(ctx, x, y, rad, ang, E, o) {
  const nz = noise1(o.seed), notch = .32, pts = [[x, y]];
  for (let i = 0; i <= 44; i++) { const t = ang + notch / 2 + (TAU - notch) * i / 44, rr = rad * (1 + nz(i * .5) * .05); pts.push([x + Math.cos(t) * rr, y + Math.sin(t) * rr * SQ]); }
  ctx.fillStyle = rgba(o.fill, E.dark ? .96 : .88); ctx.fill(poly(shift(pts, 3 * E.u, 2.2 * E.u)));
  const sh = poly(pts);
  if (!E.dark) hatch(ctx, sh, { x: x - rad, y: y, w: rad * 2, h: rad }, -1.1, 4.4, E.pal.ink, .1, .6, o.seed + 4);
  ink(ctx, pts, { w: 1.3 * E.lw, color: E.pal.ink, alpha: o.alpha, seed: o.seed, closed: true, amp: .4 });
  for (let k = 1; k < 12; k++) { const t = ang + notch / 2 + (TAU - notch) * k / 12; ink(ctx, [[x + Math.cos(t) * rad * .1, y + Math.sin(t) * rad * .1 * SQ], [x + Math.cos(t) * rad * .86, y + Math.sin(t) * rad * .86 * SQ]], { w: .7 * E.lw, color: E.pal.ink, alpha: o.alpha * .32, seed: o.seed + k, amp: .2, t0: 2, t1: 8 }); }
}
function lotus(ctx, x, y, s, E, seed, alpha) {
  // a lotus flower: a cup of pointed petals on a short stem above the water
  ink(ctx, quad([x, y + s * 1.6], [x + s * .2, y + s * .8], [x, y], 8), { w: 1.4 * E.lw, color: E.pal.ink, alpha, seed, amp: .2, t0: 1, t1: 1 });
  const petals = [[-.95, .15, -.9], [.95, .15, .9], [-.5, -.15, -.35], [.5, -.15, .35], [0, -.25, 0]];
  petals.forEach(([dx, dy, rot], k) => {
    const pts = []; for (let i = 0; i <= 16; i++) { const t = i / 16 * TAU; pts.push([Math.sin(t) * s * .42 * (1 - .15 * Math.cos(t)), -(.5 - .5 * Math.cos(t)) * s * 1.25]); }
    const Pp = rotPts(pts.map(([a, b]) => [x + dx * s * .45 + a, y + dy * s + b]), rot * .55, x + dx * s * .45, y + dy * s);
    ctx.fillStyle = rgba(E.pal.lotus, E.dark ? .8 : .88); ctx.fill(poly(shift(Pp, 1.6, 1.2)));
    ink(ctx, Pp, { w: 1 * E.lw, color: E.pal.ink, alpha, seed: seed + 3 + k, closed: true, amp: .2, step: 1.6 });
  });
}
function koi(ctx, x, y, s, a, color, E) {
  const body = rotPts([[x - s, y], [x - s * .35, y - s * .3], [x + s * .5, y - s * .17], [x + s * .9, y], [x + s * .5, y + s * .17], [x - s * .35, y + s * .3]], a, x, y);
  const tail = rotPts([[x + s * .85, y], [x + s * 1.4, y - s * .32], [x + s * 1.22, y], [x + s * 1.4, y + s * .32]], a, x, y);
  ctx.fillStyle = rgba(color, E.dark ? .7 : .55); ctx.fill(poly(spline(body, true, 5))); ctx.fill(poly(tail));
}
function waterLines(ctx, E, n, box, seed, alpha) {
  const r = rng(seed);
  for (let i = 0; i < n; i++) {
    const x = box.x + r() * box.w, y = box.y + r() * box.h, w = (14 + r() * 26) * E.u;
    const pts = []; for (let k = 0; k <= 10; k++) pts.push([x + w * k / 10, y + Math.sin(k / 10 * Math.PI * 2 + r()) * 1.6]);
    ink(ctx, pts, { w: 1.1 * E.lw, color: E.pal.ink, alpha: alpha * (.5 + r() * .5), seed: seed + i, amp: .2, t0: 5, t1: 5 });
  }
}
SCENES.suimon = {
  zh: '蓮池', en: 'Lotus pond', variants: { day: '蓮池 Lotus pond', night: '月の池 Moon pond' },
  draw(ctx, E, dyn) {
    const { W, H, pal, r, u } = E, night = E.dark, ph = E.phone, la = night ? .42 : .62;
    // moonlight laid on the water
    if (night) {
      const mx = W * (ph ? .76 : .82), top = H * (ph ? .04 : .03), bot = H * (ph ? .42 : .55);
      glow(ctx, mx, top + (bot - top) * .25, W * .3, pal.moon, .05);
      for (let k = 0; k < (ph ? 34 : 56); k++) {
        const t = Math.pow(r(), 1.3), y = top + (bot - top) * t, w = (ph ? 44 : 70) * u * (1 - t * .6) * (.35 + r() * .8), x = mx + (r() - .5) * 34 * u * (1 + t * 1.5);
        const pts = []; for (let q = 0; q <= 8; q++) pts.push([x - w / 2 + w * q / 8, y + Math.sin(q * .9 + k) * 1.2]);
        ink(ctx, pts, { w: (1.8 - t) * 1.2, color: pal.moon, alpha: (.7 - t * .45) * (.45 + r() * .55), seed: 500 + k, amp: .3, t0: 8, t1: 8 });
      }
    }
    // koi shadows under the water
    (ph ? [[.8, .78, -.5, pal.koi], [.55, .06, 2.7, pal.fish]] : [[.88, .62, -.4, pal.koi], [.13, .3, 2.6, pal.fish], [.94, .7, -.6, pal.fish]]).forEach(([x, y, a, c]) => koi(ctx, W * x, H * y, 34 * u, a, c, E));
    // water lines in the margins
    waterLines(ctx, E, ph ? 10 : 22, { x: 0, y: H * .02, w: W * .2, h: H * .96 }, 610, night ? .22 : .3);
    waterLines(ctx, E, ph ? 10 : 22, { x: W * .8, y: H * .02, w: W * .2, h: H * .96 }, 620, night ? .22 : .3);
    // ripple rings
    const centers = ph ? [[.2, .9, 6], [.86, .12, 5], [.84, .64, 4]] : [[.1, .84, 7], [.93, .2, 6], [.7, .94, 5], [.06, .1, 4], [.3, .96, 4]];
    centers.forEach(([x, y, n], i) => ripple(ctx, W * x, H * y, (10 + r() * 6) * u, n, E, 700 + i * 31, night ? .32 : .5));
    // pads: a big cluster bottom-left, a smaller one top-right
    const pads = ph
      ? [[.12, .84, 46, .6], [.34, .91, 30, 2.2], [.05, .95, 26, 4], [.88, .1, 34, 3], [.72, .05, 22, 1]]
      : [[.07, .78, 74, .6], [.19, .9, 50, 2.3], [.03, .93, 40, 4.1], [.27, .975, 30, 1.5], [.92, .13, 56, 3.1], [.83, .06, 34, 1.2], [.98, .3, 30, 5]];
    pads.forEach(([x, y, s, a], i) => lotusPad(ctx, W * x, H * y, s * u, a, E, { seed: 800 + i * 9, fill: i % 2 ? pal.pad2 : pal.pad, alpha: la }));
    lotus(ctx, W * (ph ? .2 : .12), H * (ph ? .8 : .72), (ph ? 13 : 18) * u, E, 900, la);
    if (!ph) lotus(ctx, W * .88, H * .07, 12 * u, E, 910, la);
    // floating ginkgo and petals that bob
    const floats = ph ? [['g', .5, .95, -.4], ['p', .72, .9, .8], ['p', .93, .64, 2], ['p', .06, .74, -1]] : [['g', .25, .83, -.6], ['g', .86, .34, .9], ['p', .33, .9, .3], ['p', .78, .88, 2.1], ['p', .95, .45, -.8], ['p', .05, .22, 1.2], ['p', .58, .97, .4]];
    floats.forEach(([kind, x, y, a], i) => {
      const fx = W * x, fy = H * y;
      ripple(ctx, fx, fy, 14 * u, 2, E, 950 + i, night ? .2 : .3);
      dyn.push({ draw(g, t) {
        const bob = t ? Math.sin(t * .6 + i * 1.3) : 0, rot = a + bob * .06;
        if (kind === 'g') ginkgo(g, fx + bob * 2, fy + (t ? Math.cos(t * .5 + i) * 1.4 : 0), 16 * u, rot, E, 60 + i);
        else petal(g, fx + bob * 2, fy + (t ? Math.cos(t * .5 + i) * 1.4 : 0), 9 * u, rot, E, 80 + i, night ? .75 : 1);
      } });
    });
    const spots = []; for (let i = 0; i < 6; i++) spots.push([r(), r(), r() * 10]);
    dyn.push({ motionOnly: true, draw(g, t) {
      spots.forEach(s => {
        const T = ((t + s[2]) % 7) / 7; if (T > .8) return;
        let x = s[0] * W; const y = s[1] * H; if (x > W * .22 && x < W * .78) x = x < W / 2 ? x * .3 : W - (W - x) * .3;
        for (let k = 0; k < 3; k++) {
          const rad = (6 + T * 50 - k * 11) * u; if (rad < 1) continue;
          g.strokeStyle = rgba(pal.ink, (night ? .3 : .45) * (1 - T / .8) * (1 - k * .25)); g.lineWidth = 1;
          g.beginPath(); g.ellipse(x, y, rad, rad * SQ, 0, 0, TAU); g.stroke();
        }
      });
    } });
  }
};
function ginkgo(ctx, x, y, s, ang, E, seed) {
  const pts = [[0, 0]];
  for (let i = 0; i <= 14; i++) { const t = i / 14, a = -Math.PI / 2 - .95 + t * 1.9, rr = s * (1 + (Math.abs(t - .5) < .06 ? -.18 : 0)); pts.push([Math.cos(a) * rr, Math.sin(a) * rr]); }
  const Pp = rotPts(pts.map(([a, b]) => [x + a, y + b]), ang, x, y);
  ctx.fillStyle = rgba(E.pal.ginkgo, .85); ctx.fill(poly(shift(Pp, 1.8, 1.4)));
  ink(ctx, Pp, { w: 1 * E.lw, color: E.pal.ink, alpha: .6, seed, closed: true, amp: .2, step: 1.6 });
  ink(ctx, rotPts([[x, y], [x, y + s * .55]], ang, x, y), { w: 1, color: E.pal.ink, alpha: .55, seed: seed + 1, amp: .1, t0: 1, t1: 3 });
  for (let k = 0; k < 5; k++) { const a = -Math.PI / 2 - .7 + k * .35; ink(ctx, rotPts([[x + Math.cos(a) * s * .2, y + Math.sin(a) * s * .2], [x + Math.cos(a) * s * .85, y + Math.sin(a) * s * .85]], ang, x, y), { w: .6, color: E.pal.ink, alpha: .25, seed: seed + 5 + k, amp: .1, t0: 1, t1: 1 }); }
}
function petal(ctx, x, y, s, ang, E, seed, alpha = 1) {
  const pts = []; for (let i = 0; i < 16; i++) { const t = i / 16 * TAU; let rr = s * (1 - .25 * Math.cos(t)); if (Math.abs(Math.sin(t / 2)) < .12) rr *= .75; pts.push([Math.cos(t) * rr * .62, Math.sin(t) * rr * .42]); }
  const Pp = rotPts(pts.map(([a, b]) => [x + a, y + b]), ang, x, y);
  ctx.fillStyle = rgba(E.pal.petal, .85 * alpha); ctx.fill(poly(shift(Pp, 1.4, 1.1)));
  ink(ctx, Pp, { w: .9 * E.lw, color: E.pal.ink, alpha: .45 * alpha, seed, closed: true, amp: .15, step: 1.4 });
}

// 小町 Little town ---------------------------------------------------------
function house(ctx, x, y, w, E, o) {
  const { pal } = E, r = rng(o.seed), h = w * (o.tall || (.6 + r() * .22)), roofH = w * (.36 + r() * .16), lw = E.lw, la = o.alpha;
  const body = [[x, y], [x, y - h], [x + w, y - h], [x + w, y]];
  const over = w * .09;
  const roof = [[x - over, y - h + 1], [x + w * .5, y - h - roofH], [x + w + over, y - h + 1]];
  let chim = null;
  if (o.chimney) {
    const cx = x + w * (o.flip ? .22 : .7), cw = w * .11;
    const ch = [[cx, y - h - roofH * .25], [cx, y - h - roofH * 1.0], [cx + cw, y - h - roofH * 1.0], [cx + cw, y - h - roofH * .2]];
    ctx.fillStyle = rgba(o.roof, .85); ctx.fill(poly(shift(ch, 1.6, 1.2)));
    ink(ctx, ch, { w: 1.2 * lw, color: pal.ink, alpha: la, seed: o.seed + 9, amp: .2, t0: 1, t1: 1 });
    chim = [cx + cw / 2, y - h - roofH * 1.05];
  }
  ctx.fillStyle = rgba(o.wall || pal.wall, 1); ctx.fill(poly(shift(body, 2.4, 1.8)));
  ctx.fillStyle = rgba(o.roof, E.dark ? .95 : .86); ctx.fill(poly(shift(roof, 2.8, 2.2)));
  hatch(ctx, poly(roof), bbox(roof), -1.05, 3.6, pal.ink, E.dark ? .14 : .2, .6, o.seed + 3);
  if (!E.dark) hatch(ctx, poly(body), { x: x + w * .7, y: y - h, w: w * .3, h }, -1.2, 4.5, pal.ink, .09, .6, o.seed + 4);
  ink(ctx, body, { w: 1.35 * lw, color: pal.ink, alpha: la, seed: o.seed, closed: true, amp: .35, sketch: true });
  ink(ctx, roof, { w: 1.4 * lw, color: pal.ink, alpha: la, seed: o.seed + 1, closed: true, amp: .35 });
  const dw = w * .22, dh = h * .56, dx = x + w * (o.flip ? .18 : .6);
  const door = [[dx, y], [dx, y - dh], [dx + dw, y - dh], [dx + dw, y]];
  ctx.fillStyle = rgba(pal.door, .72); ctx.fill(poly(door));
  ink(ctx, door, { w: 1 * lw, color: pal.ink, alpha: la * .9, seed: o.seed + 2, amp: .2, t0: 1, t1: 1 });
  const wins = [];
  const ww = w * .2, wx = x + w * (o.flip ? .58 : .16), wy = y - h * .78;
  wins.push([wx, wy]); if (h > w * .7) wins.push([wx, wy + ww * 1.5]);
  wins.forEach(([qx, qy], k) => {
    const win = [[qx, qy], [qx + ww, qy], [qx + ww, qy + ww], [qx, qy + ww]];
    const lit = E.dark && (o.lit == null ? r() < .7 : o.lit);
    if (lit) { glow(ctx, qx + ww / 2, qy + ww / 2, ww * 3.4, pal.window, .2); ctx.fillStyle = rgba(pal.window, .95); }
    else ctx.fillStyle = rgba(pal.glass, E.dark ? .8 : .7);
    ctx.fill(poly(win));
    ink(ctx, win, { w: .9 * lw, color: pal.ink, alpha: la * .9, seed: o.seed + 5 + k, closed: true, amp: .15, step: 1.6 });
    ink(ctx, [[qx + ww / 2, qy], [qx + ww / 2, qy + ww]], { w: .7, color: pal.ink, alpha: la * .7, seed: o.seed + 7 + k, amp: .1, t0: 0, t1: 0 });
  });
  return { chimney: chim, top: y - h - roofH, x, w };
}
function pole(ctx, x, ground, h, E, seed, alpha) {
  ink(ctx, [[x, ground], [x + .8, ground - h]], { w: 3 * E.lw, color: E.pal.ink, alpha, seed, amp: .3, t0: 0, t1: 3 });
  ink(ctx, [[x - 14 * E.u, ground - h + 10 * E.u], [x + 14 * E.u, ground - h + 9 * E.u]], { w: 1.8 * E.lw, color: E.pal.ink, alpha, seed: seed + 1, amp: .2, t0: 1, t1: 1 });
  ink(ctx, [[x - 9 * E.u, ground - h + 22 * E.u], [x + 9 * E.u, ground - h + 21.5 * E.u]], { w: 1.5 * E.lw, color: E.pal.ink, alpha, seed: seed + 2, amp: .2, t0: 1, t1: 1 });
  return [[x - 12 * E.u, ground - h + 9 * E.u], [x + 12 * E.u, ground - h + 8.5 * E.u], [x, ground - h + 20 * E.u]];
}
function perch(ctx, x, y, s, E, seed, flip) {
  // a small bird sitting on a wire
  const d = flip ? -1 : 1;
  const body = blobPts(x, y - s * .55, s * .62, seed, 16, .05, .8);
  ctx.fillStyle = rgba(E.pal.ink, E.dark ? .55 : .75); ctx.fill(poly(body));
  ctx.beginPath(); ctx.arc(x + d * s * .45, y - s * 1.05, s * .33, 0, TAU); ctx.fill();
  ctx.beginPath(); ctx.moveTo(x - d * s * .5, y - s * .55); ctx.lineTo(x - d * s * 1.1, y - s * .2); ctx.lineTo(x - d * s * .5, y - s * .3); ctx.fill();
  ctx.beginPath(); ctx.moveTo(x + d * s * .74, y - s * 1.08); ctx.lineTo(x + d * s * 1.0, y - s * 1.0); ctx.lineTo(x + d * s * .74, y - s * .95); ctx.fill();
}
SCENES.machi = {
  zh: '小町', en: 'Little town', variants: { day: '昼の町 Town by day', night: '灯りの町 Lamplit town' },
  draw(ctx, E, dyn) {
    const { W, H, pal, r, u } = E, night = E.dark, ph = E.phone, la = night ? .5 : .7;
    const ground = H * (ph ? .875 : .935);
    if (night) glow(ctx, W * (ph ? .78 : .1), H * .1, W * .4, pal.moon, .05);
    // the back row: only roofs and upper walls show, lighter
    const lane = ground - (ph ? 26 : 38) * u;
    const back = ph ? [[.08, 44], [.42, 40], [.7, 48]] : [[.02, 64], [.12, 56], [.6, 60], [.7, 70], [.85, 56]];
    back.forEach(([x, w], i) => house(ctx, W * x, lane + 2, w * u, E, { seed: 2000 + i * 13, roof: mix(pal.roofs[(i + 2) % pal.roofs.length], pal.paper, .35), wall: pal.wall2, alpha: la * .65, chimney: i % 2 === 1, flip: i % 2 === 0 }));
    const laneLine = ridge(E, lane, 2 * u, 70, 1.3);
    gouache(ctx, poly(laneLine.concat([[W + 30, H + 10], [-30, H + 10]])), mix(pal.ground, pal.paper, .45), { seed: 69, texture: .3 });
    ink(ctx, laneLine, { w: 1.1 * E.lw, color: pal.ink, alpha: la * .55, seed: 68, amp: .4, t0: 0, t1: 0 });
    for (let x = -10, k = 0; x < W + 10; k++) {
      const s = (ph ? 7 : 9) * u * (.8 + r() * .5), o = cloudOutline(x, lane + 3, s * 2.6, rng(2100 + k));
      ctx.fillStyle = rgba(pal.tree, night ? .9 : .7); ctx.fill(poly(shift(o.pts, 2, 1.5)));
      ink(ctx, o.pts, { w: 1 * E.lw, color: pal.ink, alpha: la * .5, seed: 2200 + k, closed: true, amp: .3 });
      x += s * 2.6 + (r() < .3 ? r() * 60 * u : 0);
    }
    // the ground strip
    const groundLine = ridge(E, ground, 2 * u, 71, 1.5);
    gouache(ctx, poly(groundLine.concat([[W + 30, H + 10], [-30, H + 10]])), pal.ground, { seed: 72, texture: .4 });
    ink(ctx, groundLine, { w: 1.3 * E.lw, color: pal.ink, alpha: la * .8, seed: 73, amp: .4, t0: 0, t1: 0 });
    stipple(ctx, poly(groundLine.concat([[W + 30, H + 10], [-30, H + 10]])), { x: 0, y: ground, w: W, h: H - ground }, ph ? 90 : 260, pal.ink, night ? .14 : .2, 74);
    // the front row of houses, with trees between them
    const front = ph ? [[.0, 64], [.27, 54], [.55, 68]] : [[.0, 88], [.085, 72], [.2, 80], [.63, 78], [.745, 94], [.875, 74]];
    const chimneys = [];
    front.forEach(([x, w], i) => {
      const hs = house(ctx, W * x + 4, ground + 2, w * u, E, { seed: 1000 + i * 17, roof: pal.roofs[i % pal.roofs.length], chimney: i % 2 === 0, flip: i % 2 === 1, alpha: la });
      if (hs.chimney) chimneys.push(hs.chimney);
    });
    const trees = ph ? [[.47, 13, 0], [.9, 17, 1]] : [[.29, 18, 0], [.33, 13, 2], [.58, 16, 1], [.97, 20, 0]];
    trees.forEach(([x, s, k], i) => tree(ctx, W * x, ground + 2, s * u, E, { seed: 1200 + i, kind: k, alpha: la }));
    // telephone poles and their wires, with birds sitting on them
    const poles = ph ? [.12, .88] : [.04, .46, .93];
    const tops = poles.map((x, i) => pole(ctx, W * x, ground + 3, (ph ? 150 : 210) * u, E, 1300 + i * 5, la));
    const wires = [];
    for (let i = 0; i + 1 < tops.length; i++) for (let k = 0; k < 3; k++) {
      const a = tops[i][k], b = tops[i + 1][k], sag = (ph ? 26 : 38) * u * (1 + k * .15);
      const w = quad(a, [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2 + sag * 2], b, 40);
      ink(ctx, w, { w: .9 * E.lw, color: pal.ink, alpha: la * .75, seed: 1400 + i * 3 + k, amp: .2, t0: 0, t1: 0, step: 4 });
      wires.push(w);
    }
    const birds = ph ? [[0, .3], [0, .36], [0, .7]] : [[0, .22], [0, .27], [0, .33], [1, .7], [3, .55], [3, .6]];
    birds.forEach(([wi, t], i) => { const w = wires[wi % wires.length]; const p = w[Math.round(t * (w.length - 1))]; perch(ctx, p[0], p[1], 5.5 * u, E, 1500 + i, i % 3 === 0); });
    // lamps by the doors
    (ph ? [.24, .52] : [.18, .62, .85]).forEach((x, i) => {
      const lx = W * x, ly = ground + 2, s = 28 * u;
      ink(ctx, [[lx, ly], [lx, ly - s]], { w: 1.4, color: pal.ink, alpha: la, seed: 1600 + i, amp: .1, t0: 0, t1: 0 });
      const box = [[lx - 4, ly - s], [lx + 4, ly - s], [lx + 4, ly - s - 8], [lx - 4, ly - s - 8]];
      if (night) glow(ctx, lx, ly - s - 4, 34 * u, pal.window, .24);
      ctx.fillStyle = rgba(night ? pal.window : '#e4cf8f', .92); ctx.fill(poly(box));
      ink(ctx, box, { w: 1, color: pal.ink, alpha: la, seed: 1610 + i, closed: true, amp: .1, step: 1.2 });
    });
    for (let k = 0; k < (ph ? 12 : 30) * E.density; k++) { const x = r() * W; tuft(ctx, x, ground + 6 + r() * (H - ground - 8), (6 + r() * 6) * u, pal.ink, night ? .3 : .45, r, 1); }
    if (!night) {
      const clouds = ph ? [[W * .52, H * .05, W * .4, 2.4]] : [[W * .04, H * .14, W * .14, 2.6], [W * .7, H * .12, W * .11, 3.6]];
      clouds.forEach((c, i) => driftCloud(dyn, E, c[0], c[1], c[2], 160 + i, c[3]));
    } else {
      const mx = W * (ph ? .8 : .1), my = H * (ph ? .08 : .11), mr = (ph ? 20 : 26) * u;
      const moon = moonSprite(E, mr, pal.moon, 5, .5);
      ctx.drawImage(moon, mx - mr - 10, my - mr - 10, moon.cssW, moon.cssH);
      starField(dyn, E, Math.round((ph ? 16 : 36) * E.density), [.02, ph ? .35 : .5], pal.star, pal.star, 170);
    }
    dyn.push({ motionOnly: true, draw(g, t) {
      chimneys.forEach((c, i) => {
        for (let k = 0; k < 4; k++) {
          const T = ((t * .12 + k * .25 + i * .1) % 1), x = c[0] + Math.sin(T * 5 + i) * 6 + T * 16, y = c[1] - T * 60 * u, s = (3 + T * 8) * u;
          g.fillStyle = rgba(night ? '#55524b' : '#fbf8f2', .75 * (1 - T)); g.beginPath(); g.ellipse(x, y, s, s * .75, 0, 0, TAU); g.fill();
          g.strokeStyle = rgba(pal.ink, .4 * (1 - T)); g.lineWidth = 1; g.stroke();
        }
      });
      const T = (t * .03) % 1, x = -20 + T * (W + 40), y = ground + (H - ground) * .45;
      const env = [[x - 8, y - 5.5], [x + 8, y - 5.5], [x + 8, y + 5.5], [x - 8, y + 5.5]];
      g.fillStyle = night ? '#e9e2d1' : '#fffdf8'; g.fill(poly(env));
      g.strokeStyle = rgba(pal.ink, .75); g.lineWidth = 1; g.stroke(poly(env));
      g.beginPath(); g.moveTo(x - 8, y - 5.5); g.lineTo(x, y + 1); g.lineTo(x + 8, y - 5.5); g.stroke();
      g.fillStyle = rgba(pal.roofs[0], .95); g.beginPath(); g.arc(x, y + 1, 2, 0, TAU); g.fill();
    } });
  }
};

// 山並 Ridges and haze --------------------------------------------------------
function peaks(E, y0, amp, seed, shape) {
  const r = rng(seed); let pts = [];
  const n = 9;
  for (let i = 0; i <= n; i++) { const t = i / n; pts.push([-40 + (E.W + 80) * t, y0 - amp * shape(t) * (.6 + r() * .4)]); }
  let disp = amp * .3;
  for (let d = 0; d < 6; d++) {
    const out = [];
    for (let i = 0; i < pts.length - 1; i++) { const a = pts[i], b = pts[i + 1]; out.push(a); out.push([(a[0] + b[0]) / 2 + (r() - .5) * (b[0] - a[0]) * .2, (a[1] + b[1]) / 2 + (r() - .5) * disp]); }
    out.push(pts[pts.length - 1]); pts = out; disp *= .5;
  }
  return pts;
}
function kasumi(ctx, x, y, w, E, seed, o = {}) {
  // stacked haze bars, as in old scroll paintings: a union of soft rounded bars
  const r = rng(seed), bh = (o.h || 15) * E.u;
  const bars = [[0, 0, 1], [w * (.12 + r() * .15), -bh * .78, .55 + r() * .2], [-w * (.08 + r() * .1), bh * .78, .62 + r() * .2]];
  const shapes = bars.map(([dx, dy, k], i) => {
    const bw = w * k, x0 = x + dx, y0 = y + dy, pts = [];
    for (let j = 0; j <= 10; j++) { const a = -Math.PI / 2 - Math.PI * j / 10; pts.push([x0 + Math.cos(a) * bh / 2, y0 + Math.sin(a) * bh / 2]); }
    for (let j = 0; j <= 10; j++) { const a = Math.PI / 2 - Math.PI * j / 10; pts.push([x0 + bw + Math.cos(a) * bh / 2, y0 + Math.sin(a) * bh / 2]); }
    return wobble(resampleClosed(pts, 3), .5, .03, seed + i, true);
  });
  ctx.save();
  ctx.strokeStyle = rgba(E.pal.ink, o.alpha); ctx.lineWidth = 2.2 * E.lw; ctx.lineJoin = 'round';
  shapes.forEach(s => ctx.stroke(poly(s)));
  ctx.fillStyle = rgba(E.pal.kasumi, 1);
  shapes.forEach(s => ctx.fill(poly(s)));
  ctx.restore();
}
function zuiun(ctx, x, yb, w, E, seed, o = {}) {
  // an auspicious cloud: bumps on top, a curl in each bump and a long trailing tail
  const r = rng(seed), c = cloudOutline(x, yb, w, r), la = o.alpha;
  const tail = [];
  for (let k = 0; k <= 24; k++) { const t = k / 24; tail.push([x + w - c.h * .2 + t * w * .7, yb - c.h * .18 - t * c.h * .3 + Math.sin(t * Math.PI * 1.6) * c.h * .16]); }
  ink(ctx, tail, { w: 1.5 * E.lw, color: E.pal.ink, alpha: la * .9, seed: seed + 50, amp: .2, t0: 2, t1: 60 });
  const tail2 = tail.map(([px, py], k) => [px - 10, py + c.h * .2 + k * .2]);
  ink(ctx, tail2.slice(0, 18), { w: 1.1 * E.lw, color: E.pal.ink, alpha: la * .6, seed: seed + 51, amp: .2, t0: 2, t1: 40 });
  ctx.fillStyle = rgba(o.fill, o.fillAlpha == null ? .96 : o.fillAlpha); ctx.fill(poly(shift(c.pts, 2.5, 2)));
  ink(ctx, c.pts, { w: 1.4 * E.lw, color: E.pal.ink, alpha: la, seed, closed: true, amp: .4 });
  c.circles.slice(2).forEach(([cx, cy, rad], i) => {
    const pts = [];
    for (let k = 0; k <= 30; k++) { const t = k / 30, a = Math.PI * .95 + t * Math.PI * 1.7, rr = rad * .62 * (1 - t * .7); pts.push([cx - rad * .05 + Math.cos(a) * rr, cy + rad * .32 + Math.sin(a) * rr]); }
    ink(ctx, pts, { w: 1.1 * E.lw, color: E.pal.ink, alpha: la * .75, seed: seed + 5 + i, amp: .1, t0: 3, t1: 6 });
  });
}
function pine(ctx, px, py, sc, E, seed, la) {
  const r = rng(seed), pal = E.pal;
  const trunk = spline([[px, py + 8], [px + 7 * sc, py - 34 * sc], [px - 9 * sc, py - 68 * sc], [px + 3 * sc, py - 104 * sc]], false, 10);
  const pads = [[-1, .3, 74], [1, .45, 68], [-1, .66, 58], [1, .82, 50], [0, 1, 44]];
  const centers = pads.map(([side, t, w]) => { const p = trunk[Math.round(t * (trunk.length - 1))]; return [p[0] + side * w * .42 * sc, p[1] - 4 * sc, w * sc, p]; });
  ink(ctx, trunk, { w: 4.4 * sc, color: pal.ink, alpha: la, seed, amp: .6, t0: 0, t1: 30, sketch: .3 });
  centers.forEach(([cx, cy, w, p], k) => { if (Math.abs(cx - p[0]) > 4) ink(ctx, quad(p, [(p[0] + cx) / 2, p[1] - 6 * sc], [cx, cy], 10), { w: 2.2 * sc, color: pal.ink, alpha: la, seed: seed + 10 + k, amp: .3, t0: 0, t1: 14 }); });
  centers.forEach(([cx, cy, w], k) => {
    const o = cloudOutline(cx - w / 2, cy + 6 * sc, w, rng(seed + 20 + k));
    ctx.fillStyle = rgba(pal.pine, E.dark ? .96 : .82); ctx.fill(poly(shift(o.pts, 2.6, 2.2)));
    if (!E.dark) hatch(ctx, poly(o.pts), { x: cx - w / 2, y: cy - 2 * sc, w, h: 10 * sc }, -.25, 2.6, pal.ink, .28, .6, seed + 30 + k);
    ink(ctx, o.pts, { w: 1.2 * E.lw, color: pal.ink, alpha: la * .9, seed: seed + 40 + k, closed: true, amp: .4 });
  });
}
SCENES.yamanami = {
  zh: '山並', en: 'Ridges', variants: { day: '朝の山 Morning ridges', night: '月の山 Moonlit ridges' },
  draw(ctx, E, dyn) {
    const { W, H, pal, r, u } = E, night = E.dark, ph = E.phone;
    const sx = W * (ph ? .6 : .84), sy = H * (ph ? .062 : .16), sr = (ph ? 19 : 34) * u;
    if (night) { glow(ctx, sx, sy, sr * 8, pal.moon, .06); glow(ctx, sx, sy, sr * 2.4, pal.moon, .1); }
    gouache(ctx, poly(blobPts(sx, sy, sr, 9, 40, .025)), night ? pal.moon : pal.sun, { seed: 10, texture: .6, alpha: night ? .95 : .82 });
    if (night) starField(dyn, E, Math.round((ph ? 18 : 40) * E.density), [.02, ph ? .3 : .45], pal.star, pal.star, 180);
    // ridges: high at the sides, low in the middle
    const base = ph ? .9 : .9;
    const sides = (t, k) => Math.pow(Math.abs(t - .5) * 2, k) * .88 + .12;
    const layers = ph
      ? [[.13, .12, 1.4], [.07, .095, 1.9], [.02, .07, 2.4], [-.03, .045, 2.8]]
      : [[.17, .3, 1.5], [.1, .24, 2], [.04, .17, 2.6], [-.02, .09, 3]];
    let prev = null;
    layers.forEach(([dy, amp, k], i) => {
      const y = H * (base - dy), line = peaks(E, y, H * amp, E.seed + 90 + i, t => sides(t, k));
      const shape = poly(line.concat([[W + 40, H + 10], [-40, H + 10]]));
      gouache(ctx, shape, pal.ridges[i], { seed: 100 + i, texture: night ? .35 : .5, light: mix(pal.ridges[i], '#ffffff', night ? .05 : .25), dark: mix(pal.ridges[i], '#000000', night ? .2 : .08), angle: -.15 });
      if (!night && i > 0) hatch(ctx, shape, { x: 0, y: y - H * amp, w: W, h: H * amp * 1.4 }, -1.25, 5.5, pal.ink, .06 + i * .015, .6, 110 + i);
      ink(ctx, line, { w: (.9 + i * .25) * E.lw, color: pal.ink, alpha: night ? .16 + i * .05 : .24 + i * .1, seed: 120 + i, amp: .3, t0: 0, t1: 0, taper: false, step: 3 });
      // haze gathering at the foot of each ridge
      if (i < 3) {
        const hz = ctx.createLinearGradient(0, y - H * .01, 0, y + H * .07);
        hz.addColorStop(0, rgba(pal.paper, 0)); hz.addColorStop(.55, rgba(pal.paper, night ? .35 : .55)); hz.addColorStop(1, rgba(pal.paper, 0));
        ctx.save(); ctx.clip(shape); ctx.fillStyle = hz; ctx.fillRect(0, y - H * .01, W, H * .08); ctx.restore();
      }
      prev = line;
    });
    void prev;
    // pines on the nearest ridge
    const pines = ph ? [[.1, .8], [.2, .55]] : [[.05, 1.1], [.115, .72], [.94, .85]];
    pines.forEach(([x, k], j) => pine(ctx, W * x, H * (base + .03), k * u, E, 160 + j * 37, night ? .5 : .72));
    // auspicious clouds drifting in the sky corners and over the ridges
    const kz = ph ? [[W * .02, H * .04, W * .3], [W * .56, H * .74, W * .24]] : [[W * .04, H * .22, W * .13], [W * .64, H * .1, W * .09], [W * .72, H * .62, W * .12]];
    kz.forEach((c, i) => {
      const spr = sprite(c[2] * 1.9, c[2] * .8 + 30, E.dpr, g => zuiun(g, 10, c[2] * .7 + 12, c[2], E, 190 + i * 7, { alpha: night ? .34 : .6, fill: pal.kasumi }));
      dyn.push({ draw(g, t) { const x = c[0] - 10 + (t ? Math.sin(t * .04 + i * 2) * 30 : 0); g.drawImage(spr, x, c[1] - c[2] * .7 - 12, spr.cssW, spr.cssH); } });
    });
    dyn.push({ draw(g, t) {
      const T = t ? (t * .012) % 1 : .62, bx = -60 + T * (W + 120), by = H * (ph ? .25 : .3) - Math.sin(T * 3) * 20;
      [[0, 0, 7], [20, 9, 6], [-16, 11, 5.4]].forEach(([dx, dy, s], k) => bird(g, bx + dx * u, by + dy * u, s * u, pal.ink, night ? .45 : .62, 210 + k, t ? (Math.sin(t * 3.5 + k) + 1) / 2 : .4));
    } });
    void r;
  }
};

// ------------------------------------------------------------------ engine
function env(W, H, o) {
  const scene = SCENES[o.scene] ? o.scene : 'nohara';
  const variants = Object.keys(SCENES[scene].variants);
  const variant = variants.includes(o.variant) ? o.variant : variants[0];
  const pal = Object.assign({}, P[scene][variant]);
  const lum = (h => { const c = hexRGB(h).map(v => v / 255); return .2126 * c[0] + .7152 * c[1] + .0722 * c[2]; })(pal.paper);
  const phone = o.device ? o.device === 'phone' : W < 700;
  const u = phone ? .8 : clamp(Math.sqrt(W * H) / 1140, .85, 1.3);
  const seed = (o.seed == null ? 7 : o.seed) + hashStr(scene + variant) % 1000;
  return { W, H, pal, scene, variant, dark: lum < .3, phone, u, lw: phone ? .92 : 1, density: o.density == null ? 1 : o.density, seed, r: rng(seed), dpr: o.dpr || 1 };
}
function render(canvas, o, withDyn) {
  const dpr = o.dpr || Math.min(2, (global.devicePixelRatio || 1));
  const W = o.width || canvas.clientWidth || canvas.width, H = o.height || canvas.clientHeight || canvas.height;
  canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
  const E = env(W, H, Object.assign({}, o, { dpr }));
  const base = withDyn ? document.createElement('canvas') : canvas;
  if (withDyn) { base.width = canvas.width; base.height = canvas.height; }
  const ctx = base.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  if (SCENES[E.scene] !== SCENES.kirigami) paper(ctx, E);
  const dyn = [];
  SCENES[E.scene].draw(ctx, E, dyn);
  if (!withDyn) { for (const d of dyn) if (!d.motionOnly) d.draw(ctx, 0); }
  if (o.grain !== false) grain(ctx, E);
  return { E, base, dyn, dpr };
}
// Names of the seventeen pictures as themes ("scene · variant").
const NAMES = {
  'nohara-day': ['野原 · 春の野', 'Meadow · spring field'],
  'nohara-night': ['野原 · 蛍', 'Meadow · fireflies'],
  'kirigami-night': ['切り紙 · 紙の夜', 'Torn paper · night'],
  'kirigami-day': ['切り紙 · 紙の朝', 'Torn paper · morning'],
  'shasen-day': ['斜線 · 空', 'Stripes · sky'],
  'shasen-sage': ['斜線 · 若草', 'Stripes · sage'],
  'shasen-butter': ['斜線 · 菜の花', 'Stripes · butter'],
  'shasen-blush': ['斜線 · 桜', 'Stripes · blush'],
  'shasen-night': ['斜線 · 設計図', 'Stripes · blueprint'],
  'tsuru-day': ['朝顔 · 朝', 'Morning glory · morning'],
  'tsuru-night': ['朝顔 · 夜の温室', 'Morning glory · night greenhouse'],
  'suimon-day': ['蓮池 · 昼', 'Lotus pond · day'],
  'suimon-night': ['蓮池 · 月の池', 'Lotus pond · moon'],
  'machi-day': ['小町 · 昼の町', 'Little town · day'],
  'machi-night': ['小町 · 灯りの町', 'Little town · lamplight'],
  'yamanami-day': ['山並 · 朝の山', 'Ridges · morning'],
  'yamanami-night': ['山並 · 月の山', 'Ridges · moonlit']
};
const OrganicBG = {
  scenes: Object.keys(SCENES).map(id => ({ id, zh: SCENES[id].zh, en: SCENES[id].en, variants: SCENES[id].variants })),
  palette(scene, variant) {
    const s = P[scene] ? scene : 'nohara', v = P[s][variant] ? variant : Object.keys(P[s])[0], p = P[s][v];
    const lum = (h => { const c = hexRGB(h).map(x => x / 255); return .2126 * c[0] + .7152 * c[1] + .0722 * c[2]; })(p.paper);
    const dark = lum < .3;
    return { paper: p.paper, ink: dark ? '#ece6d8' : '#2e2924', muted: dark ? '#b2ab9c' : '#625b51', line: p.ink, card: dark ? mix(p.paper, '#ffffff', .05) : mix(p.paper, '#ffffff', .42), accent: p.ui.accent, chosen: p.ui.chosen, mode: dark ? 'dark' : 'light' };
  },
  // Every picture as a theme: {key, scene, variant, zh, en} plus its palette colours.
  presets() {
    const out = [];
    for (const id of Object.keys(SCENES)) for (const v of Object.keys(SCENES[id].variants)) {
      const name = NAMES[id + '-' + v] || [SCENES[id].zh, SCENES[id].en];
      out.push(Object.assign({ key: 'organic-' + id + '-' + v, scene: id, variant: v, zh: name[0], en: name[1] }, OrganicBG.palette(id, v)));
    }
    return out;
  },
  paint(canvas, o = {}) { const { E } = render(canvas, o, false); return { scene: E.scene, variant: E.variant }; },
  play(canvas, o = {}) {
    const reduce = global.matchMedia && global.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduce && !o.force) { OrganicBG.paint(canvas, o); return { stop() {} }; }
    const { base, dyn, dpr } = render(canvas, o, true);
    const ctx = canvas.getContext('2d');
    let raf = 0, last = 0, stopped = false;
    const t0 = performance.now() - (o.startAt || 8) * 1000, fps = o.fps || 24;
    const frame = now => {
      if (stopped) return;
      raf = requestAnimationFrame(frame);
      if (document.hidden || now - last < 1000 / fps) return;
      last = now;
      const t = (now - t0) / 1000;
      ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.drawImage(base, 0, 0);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      for (const d of dyn) d.draw(ctx, t);
    };
    raf = requestAnimationFrame(frame);
    return { stop() { stopped = true; cancelAnimationFrame(raf); } };
  },
  // The picture as a page background: a canvas filling `host` (an empty element fixed over the
  // whole window), repainted when the window changes size. opts: {scene, variant, density,
  // grain, motion}. Returns {canvas, update(opts), stop()}.
  mount(host, o = {}) {
    const doc = host.ownerDocument || document, win = doc.defaultView || global;
    const canvas = doc.createElement('canvas');
    canvas.setAttribute('aria-hidden', 'true');
    // object-fit keeps the picture in proportion while a small height change (a phone's
    // address bar sliding away) waits for the next repaint, or is not worth one.
    canvas.style.cssText = 'position:absolute;left:0;top:0;width:100%;height:100%;display:block;object-fit:cover';
    host.replaceChildren(canvas);
    let opts = Object.assign({}, o), run = null, timer = 0, painted = [0, 0];
    const size = () => [host.clientWidth || win.innerWidth || 0, host.clientHeight || win.innerHeight || 0];
    const draw = () => {
      if (run) { run.stop(); run = null; }
      const [W, H] = size();
      if (!W || !H) return;
      // A sensible number of pixels, even on very large or very dense screens.
      const budget = opts.motion ? 4.2e6 : 8.3e6;
      const dpr = Math.max(.5, Math.min(2, win.devicePixelRatio || 1, Math.sqrt(budget / (W * H))));
      const p = Object.assign({}, opts, { width: W, height: H, dpr, device: opts.device || (W < 700 ? 'phone' : 'desktop') });
      painted = [W, H];
      if (opts.motion) run = OrganicBG.play(canvas, p); else OrganicBG.paint(canvas, p);
    };
    const resized = () => {
      clearTimeout(timer);
      timer = setTimeout(() => { const [W, H] = size(); if (W !== painted[0] || Math.abs(H - painted[1]) > painted[1] * .1) draw(); }, 200);
    };
    win.addEventListener('resize', resized);
    draw();
    return {
      canvas,
      update(next) {
        const merged = Object.assign({}, opts, next), same = JSON.stringify(merged) === JSON.stringify(opts);
        opts = merged;
        if (!same || !painted[0]) draw();
      },
      stop() { if (run) run.stop(); run = null; clearTimeout(timer); win.removeEventListener('resize', resized); canvas.remove(); }
    };
  },
  // A small preview of the whole (desktop) picture, in a canvas already laid out at its size.
  thumb(canvas, o = {}) {
    const w = canvas.clientWidth || o.width || 200, h = canvas.clientHeight || o.height || 100;
    const W = 1200, H = Math.round(W * h / w), dpr = w * Math.min(2, global.devicePixelRatio || 1) / W;
    return OrganicBG.paint(canvas, Object.assign({}, o, { width: W, height: H, dpr, device: 'desktop' }));
  },
  _internal: { SCENES, P }
};
global.OrganicBG = OrganicBG;
})(typeof window !== 'undefined' ? window : this);
