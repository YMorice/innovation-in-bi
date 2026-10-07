/* @ds-bundle: {"format":4,"namespace":"Arion","components":[]} */
/* Arion : utilitaires sans dépendance (pas de React). Expose window.Arion.
   Icônes, marque, formatage français, graphiques SVG maison (cycleTrace, wearTrend, sparkline),
   jeux de données illustratifs et thème Plotly pour l'app. */
(function () {
  "use strict";

  var uidCount = 0;
  function uid(prefix) { uidCount += 1; return (prefix || "ar") + "-" + uidCount; }

  /* Icônes : géométrie Lucide (licence ISC), trait 1,75, boîte 24 */
  var ICONS = {
    check: '<path d="M20 6 9 17l-5-5"/>',
    x: '<path d="M18 6 6 18"/><path d="m6 6 12 12"/>',
    upload: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m17 8-5-5-5 5"/><path d="M12 3v12"/>',
    download: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m7 10 5 5 5-5"/><path d="M12 15V3"/>',
    "circle-check": '<circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/>',
    "triangle-alert": '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
    "octagon-x": '<path d="M2.586 16.726A2 2 0 0 1 2 15.312V8.688a2 2 0 0 1 .586-1.414l4.688-4.688A2 2 0 0 1 8.688 2h6.624a2 2 0 0 1 1.414.586l4.688 4.688A2 2 0 0 1 22 8.688v6.624a2 2 0 0 1-.586 1.414l-4.688 4.688a2 2 0 0 1-1.414.586H8.688a2 2 0 0 1-1.414-.586z"/><path d="m15 9-6 6"/><path d="m9 9 6 6"/>',
    info: '<circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/>',
    "scan-line": '<path d="M3 7V5a2 2 0 0 1 2-2h2"/><path d="M17 3h2a2 2 0 0 1 2 2v2"/><path d="M21 17v2a2 2 0 0 1-2 2h-2"/><path d="M7 21H5a2 2 0 0 1-2-2v-2"/><path d="M7 12h10"/>',
    search: '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>',
    filter: '<path d="M22 3H2l8 9.46V19l4 2v-8.54L22 3z"/>',
    "chevron-down": '<path d="m6 9 6 6 6-6"/>',
    "arrow-right": '<path d="M5 12h14"/><path d="m12 5 7 7-7 7"/>',
    maximize: '<path d="M15 3h6v6"/><path d="M9 21H3v-6"/><path d="M21 3l-7 7"/><path d="M3 21l7-7"/>',
    table: '<path d="M12 3v18"/><rect width="18" height="18" x="3" y="3" rx="2"/><path d="M3 9h18"/><path d="M3 15h18"/>',
    activity: '<path d="M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.25.25 0 0 1-.48 0L9.24 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 4.49 12H2"/>',
    "rotate-ccw": '<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/>'
  };
  function icon(name, cls) {
    return '<svg class="ar-ico' + (cls ? " " + cls : "") + '" viewBox="0 0 24 24" aria-hidden="true">' + (ICONS[name] || "") + "</svg>";
  }
  /* La marque : un trou fraisé vu de dessus. Anneau en currentColor, alésage en signal. */
  function mark(size) {
    var s = size || 20;
    return '<svg class="ar-mark" width="' + s + '" height="' + s + '" viewBox="0 0 24 24" aria-hidden="true"><circle class="ring" cx="12" cy="12" r="10"/><circle class="bore" cx="12" cy="12" r="4.5"/></svg>';
  }

  /* Lecture des jetons */
  function css(name, el) {
    var node = el || document.documentElement;
    return getComputedStyle(node).getPropertyValue("--" + name).trim();
  }
  function ms(name, el, fallback) {
    var v = css(name, el);
    var n = parseFloat(v);
    if (isNaN(n)) return fallback || 0;
    return /ms$/.test(v) ? n : n * 1000;
  }
  function rgba(c) {
    var m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(c || "");
    if (!m) return c;
    return "rgba(" + parseInt(m[1], 16) + "," + parseInt(m[2], 16) + "," + parseInt(m[3], 16) + "," + (parseInt(m[4], 16) / 255).toFixed(3) + ")";
  }
  function reducedMotion() {
    return typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;
  }

  /* Formatage français : virgule décimale, espace fine insécable pour les milliers */
  var fmtCache = {};
  function fmt(v, digits) {
    var d = digits == null ? 1 : digits;
    if (!fmtCache[d]) fmtCache[d] = new Intl.NumberFormat("fr-FR", { minimumFractionDigits: d, maximumFractionDigits: d });
    return fmtCache[d].format(v);
  }
  var MATERIALS = { cfrp: "CFRP", ti: "Titane", al: "Aluminium" };
  var MAT_SHORT = { cfrp: "CFRP", ti: "Ti", al: "Al" };

  /* Thème : clair (Atelier) par défaut pour l'app, sombre (Scène) en option */
  function setTheme(t) {
    document.documentElement.setAttribute("data-theme", t);
    try { localStorage.setItem("arion-theme", t); } catch (e) { /* stockage indisponible */ }
  }
  function initTheme(fallback) {
    var t = fallback || "light";
    try { t = localStorage.getItem("arion-theme") || t; } catch (e) { /* stockage indisponible */ }
    document.documentElement.setAttribute("data-theme", t);
    return t;
  }

  /* Générateur pseudo-aléatoire déterministe (mulberry32) */
  function rng(seed) {
    var a = seed >>> 0;
    return function () {
      a = (a + 0x6d2b79f5) >>> 0;
      var t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  /* Données illustratives (jamais issues d'un export réel) */
  function layerAt(layers, x) {
    for (var i = 0; i < layers.length; i++) if (x >= layers[i].from && x < layers[i].to) return layers[i];
    return null;
  }
  function sampleCycle(o) {
    o = o || {};
    var rand = rng(o.seed == null ? 7 : o.seed);
    var noise = o.noise == null ? 1 : o.noise;
    var wear = o.wear == null ? 0.35 : o.wear;
    var layers = o.layers || [{ mat: "cfrp", from: 0.6, to: 6.6 }, { mat: "ti", from: 6.6, to: 14.4 }];
    var last = layers[layers.length - 1];
    var end = o.end || last.to + 1.4;
    var step = 0.05;
    var pos = [], tq = [], th = [];
    for (var k = 0; k * step <= end + 1e-9; k++) {
      var q = Math.round(k * step * 100) / 100;
      var t = 0.35, f = 0.03;
      var L = layerAt(layers, q);
      if (L) {
        var d = q - L.from;
        var ramp = Math.min(1, d / 0.5);
        if (L.mat === "cfrp") { t += ramp * (2.9 + wear * 0.6); f += ramp * (0.19 + wear * 0.05); }
        if (L.mat === "ti") { t += ramp * (7.4 + wear * 1.6) + d * 0.035; f += ramp * (0.40 + wear * 0.10); }
        if (L.mat === "al") { t += ramp * (2.4 + wear * 0.4); f += ramp * (0.10 + wear * 0.03); }
        if (L === last) {
          var rest = last.to - q;
          if (rest < 0.7) f = 0.03 + (f - 0.03) * Math.max(0.06, rest / 0.7);
          if (rest < 0.45) t = 0.35 + (t - 0.35) * Math.max(0.04, rest / 0.45);
        }
        if (o.jam && q > o.jam.from && q < o.jam.to) {
          t += 1.5 * Math.abs(Math.sin(q * 8.5)) + 0.9 * (q - o.jam.from);
          f += 0.05 * Math.abs(Math.sin(q * 6));
        }
      }
      var big = t > 0.6 ? 1 : 0.3;
      pos.push(q);
      tq.push(Math.max(0, t + (rand() - 0.5) * 0.24 * big * noise));
      th.push(Math.max(0, f + (rand() - 0.5) * 0.018 * big * noise));
    }
    var out = {
      position: pos, torque: tq, thrust: th, layers: layers,
      events: [
        { x: layers[0].from, label: "Entrée", kind: "entry" },
        { x: Math.round((last.to - 0.25) * 10) / 10, label: "Débouchage", kind: "breakthrough" }
      ]
    };
    if (o.reference) {
      var ref = sampleCycle({ layers: layers, wear: 0, noise: 0, end: end });
      out.reference = { torque: ref.torque, thrust: ref.thrust };
    }
    if (o.jam) out.anomaly = { from: o.jam.from, to: o.jam.to, label: o.jam.label || "Bourrage de copeaux probable" };
    return out;
  }
  function sampleWear(o) {
    o = o || {};
    var rand = rng(o.seed == null ? 11 : o.seed);
    var a = 8.0, b = 0.0045, c = 0.000022, thr = 9.6, now = o.now || 160;
    var f = function (n) { return a + b * n + c * n * n; };
    var holes = [], torque = [];
    for (var n = 0; n <= now; n += 4) { holes.push(n); torque.push(f(n) + (rand() - 0.5) * 0.26); }
    var cross = Math.round((-b + Math.sqrt(b * b + 4 * c * (thr - a))) / (2 * c));
    var ph = [], pv = [], lo = [], hi = [];
    for (var m = now; m <= cross + 14; m += 2) {
      var spread = 0.05 + 0.0075 * (m - now);
      ph.push(m); pv.push(f(m)); lo.push(f(m) - spread); hi.push(f(m) + spread);
    }
    return {
      holes: holes, torque: torque, threshold: thr, unit: "A",
      projection: { holes: ph, value: pv, lo: lo, hi: hi, cross: cross, margin: 9 }
    };
  }

  /* Petits outils d'échelle */
  function niceCeil(v) {
    if (v <= 0) return 1;
    var p = Math.pow(10, Math.floor(Math.log10(v)));
    var r = v / p;
    var steps = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10];
    for (var i = 0; i < steps.length; i++) if (r <= steps[i] + 1e-9) return steps[i] * p;
    return 10 * p;
  }
  function tickDec(v) {
    for (var d = 0; d < 4; d++) { var k = v * Math.pow(10, d); if (Math.abs(k - Math.round(k)) < 1e-6) return d; }
    return 3;
  }
  function maxOf(arrs) {
    var m = 0;
    arrs.forEach(function (a) { if (a) for (var i = 0; i < a.length; i++) if (a[i] > m) m = a[i]; });
    return m;
  }
  function pathOf(xs, ys, sx, sy, upto) {
    var d = "";
    for (var i = 0; i < xs.length; i++) {
      if (upto != null && xs[i] > upto) break;
      d += (i ? "L" : "M") + sx(xs[i]).toFixed(1) + " " + sy(ys[i]).toFixed(1);
    }
    return d;
  }
  function nearest(xs, v) {
    var lo = 0, hi = xs.length - 1;
    while (hi - lo > 1) { var mid = (lo + hi) >> 1; if (xs[mid] < v) lo = mid; else hi = mid; }
    return Math.abs(xs[lo] - v) <= Math.abs(xs[hi] - v) ? lo : hi;
  }
  function tween(duration, ease, cb, done) {
    if (reducedMotion() || duration <= 0) { cb(1); if (done) done(); return; }
    var start = null;
    function frame(ts) {
      if (start === null) start = ts;
      var p = Math.min(1, (ts - start) / duration);
      cb(ease ? ease(p) : p);
      if (p < 1) requestAnimationFrame(frame); else if (done) done();
    }
    requestAnimationFrame(frame);
  }
  function easeInOut(p) { return p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2; }
  function hatchDefs(id) {
    return '<pattern id="' + id + '-cfrp" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><line class="hatch-line" x1="0" y1="0" x2="0" y2="6"/><line class="hatch-line" x1="0" y1="0" x2="6" y2="0"/></pattern>' +
      '<pattern id="' + id + '-ti" width="4" height="4" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><line class="hatch-line" x1="0" y1="0" x2="0" y2="4"/></pattern>' +
      '<pattern id="' + id + '-al" width="8" height="8" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><line class="hatch-line" x1="0" y1="0" x2="0" y2="8"/></pattern>';
  }

  var SIGNALS = {
    torque: { label: "Couple broche", unit: "A", color: "sig-torque", short: "Couple" },
    thrust: { label: "Poussée", unit: "A", color: "sig-thrust", short: "Poussée" }
  };

  /* Courbe de cycle : couple et poussée en deux panneaux superposés (jamais deux axes Y),
     position du foret en abscisse, couches de matière en bandes hachurées. */
  function cycleTrace(el, data, opts) {
    var o = Object.assign({ panels: ["torque", "thrust"], hover: true, draw: false, hero: false }, opts || {});
    var id = uid("trace");
    var state = { focus: null, reveal: null };
    var geom = null;
    el.classList.add("ar-chart");

    function render() {
      var W = Math.max(280, Math.round(el.clientWidth || 640));
      var n = o.panels.length;
      var ph = o.panelHeight || (n > 1 ? 112 : 190);
      var gap = 20;
      var m = { l: o.hero ? 8 : 40, r: 12, t: 26, b: o.hero ? 22 : 34 };
      var H = m.t + n * ph + (n - 1) * gap + m.b;
      var x0 = m.l, x1 = W - m.r;
      var xs = data.position;
      var xmax = o.xmax || Math.ceil(xs[xs.length - 1]);
      var sx = function (v) { return x0 + (v / xmax) * (x1 - x0); };
      var bottom = m.t + n * ph + (n - 1) * gap;
      var s = "";
      s += '<svg viewBox="0 0 ' + W + " " + H + '" height="' + H + '" role="img" aria-label="Courbe de cycle de perçage : ' + o.panels.map(function (k) { return SIGNALS[k].label; }).join(" et ") + ' selon la position du foret">';
      s += "<defs>" + hatchDefs(id) + '<clipPath id="' + id + '-clip"><rect class="reveal" x="0" y="0" width="' + W + '" height="' + H + '"/></clipPath></defs>';

      /* Couches */
      (data.layers || []).forEach(function (L, i) {
        var a = sx(L.from), b = sx(Math.min(L.to, xmax));
        var cls = "layer" + (state.focus != null && state.focus !== i ? " is-dim" : "");
        s += '<g class="' + cls + '" data-layer="' + i + '">';
        s += '<rect x="' + a.toFixed(1) + '" y="' + m.t + '" width="' + (b - a).toFixed(1) + '" height="' + (bottom - m.t) + '" style="fill:var(--layer-' + L.mat + ')"/>';
        s += '<rect x="' + a.toFixed(1) + '" y="' + m.t + '" width="' + (b - a).toFixed(1) + '" height="' + (bottom - m.t) + '" fill="url(#' + id + "-" + L.mat + ')"/>';
        s += '<line class="layer-edge" x1="' + a.toFixed(1) + '" x2="' + a.toFixed(1) + '" y1="' + m.t + '" y2="' + bottom + '"/>';
        s += '<line class="layer-edge" x1="' + b.toFixed(1) + '" x2="' + b.toFixed(1) + '" y1="' + m.t + '" y2="' + bottom + '"/>';
        var name = (b - a) > 90 ? MATERIALS[L.mat] + " · " + fmt(L.to - L.from, 1) + " mm" : MAT_SHORT[L.mat];
        s += '<text class="layer-label" x="' + (a + 6).toFixed(1) + '" y="' + (m.t - 9) + '">' + name + "</text>";
        s += "</g>";
      });

      /* Panneaux */
      var scales = {};
      o.panels.forEach(function (key, i) {
        var top = m.t + i * (ph + gap), base = top + ph;
        var series = data[key];
        var ref = data.reference ? data.reference[key] : null;
        var ymax = (o.ymax && o.ymax[key]) || niceCeil(maxOf([series, ref]) * 1.08);
        var sy = function (v) { return base - (v / ymax) * (ph - 16); };
        scales[key] = { sy: sy, top: top, base: base };
        var dec = Math.max(tickDec(ymax), tickDec(ymax / 2));
        if (!o.hero) {
          [0, ymax / 2, ymax].forEach(function (t) {
            var y = sy(t).toFixed(1);
            if (t > 0) s += '<line class="gridline" x1="' + x0 + '" x2="' + x1 + '" y1="' + y + '" y2="' + y + '"/>';
            s += '<text class="tick" x="' + (x0 - 6) + '" y="' + y + '" dy="0.32em" text-anchor="end">' + fmt(t, t === 0 ? 0 : dec) + "</text>";
          });
          s += '<text class="panel-title" x="' + (x0 + 6) + '" y="' + (top + 12) + '">' + SIGNALS[key].label + " · " + SIGNALS[key].unit + "</text>";
        }
        s += '<line class="axisline" x1="' + x0 + '" x2="' + x1 + '" y1="' + base + '" y2="' + base + '"/>';
        if (data.anomaly) {
          var aa = sx(data.anomaly.from), ab = sx(data.anomaly.to);
          s += '<rect class="anomaly" x="' + aa.toFixed(1) + '" y="' + top + '" width="' + (ab - aa).toFixed(1) + '" height="' + ph + '"/>';
          s += '<line class="anomaly-edge" x1="' + aa.toFixed(1) + '" x2="' + ab.toFixed(1) + '" y1="' + top + '" y2="' + top + '"/>';
          if (i === 0) s += '<text class="anomaly-label" x="' + (aa + 6).toFixed(1) + '" y="' + (top + 32) + '">' + data.anomaly.label + "</text>";
        }
        s += '<g clip-path="url(#' + id + '-clip)">';
        if (o.hero) s += '<path class="hero-ghost" d="' + pathOf(xs, series, sx, sy) + '"/>';
        if (ref) s += '<path class="line line--ref" style="stroke:var(--' + SIGNALS[key].color + ')" d="' + pathOf(xs, ref, sx, sy) + '"/>';
        s += '<path class="' + (o.hero ? "hero-line" : "line") + '" data-key="' + key + '"' + (o.hero ? "" : ' style="stroke:var(--' + SIGNALS[key].color + ')"') + ' d="' + pathOf(xs, series, sx, sy) + '"/>';
        s += "</g>";
        s += '<circle class="hover-dot" r="4" data-key="' + key + '" style="fill:var(--' + (o.hero ? "text" : SIGNALS[key].color) + ')" cx="-10" cy="-10"/>';
      });

      /* Événements (entrée, débouchage) */
      (data.events || []).forEach(function (ev) {
        if (o.hero && ev.kind !== "breakthrough") return;
        var x = sx(ev.x);
        var right = x > x1 - 140;
        s += '<g class="evt evt--' + ev.kind + '" data-x="' + ev.x + '"' + (o.draw && !reducedMotion() ? ' style="opacity:0"' : "") + ">";
        s += '<line class="event" x1="' + x.toFixed(1) + '" x2="' + x.toFixed(1) + '" y1="' + (m.t - 4) + '" y2="' + bottom + '"/>';
        if (ev.kind === "breakthrough") {
          s += '<text class="event-label" x="' + (right ? x - 6 : x + 6).toFixed(1) + '" y="' + (m.t + (o.hero ? 14 : 12)) + '" text-anchor="' + (right ? "end" : "start") + '">' + ev.label + " " + fmt(ev.x, 1) + " mm</text>";
          if (o.hero) {
            var k0 = o.panels[0], sc = scales[k0];
            var yi = data[k0][nearest(xs, ev.x - 0.3)];
            s += '<g class="signal"><circle class="signal-halo" cx="' + x.toFixed(1) + '" cy="' + sc.sy(yi).toFixed(1) + '" r="4"/><circle class="signal-dot" cx="' + x.toFixed(1) + '" cy="' + sc.sy(yi).toFixed(1) + '" r="4.5"/></g>';
          }
        }
        s += "</g>";
      });

      /* Axe des positions */
      var stepX = xmax > 12 ? 2 : 1;
      for (var t = 0; t <= xmax + 1e-9; t += stepX) {
        s += '<text class="tick" x="' + sx(t).toFixed(1) + '" y="' + (bottom + 14) + '" text-anchor="middle">' + fmt(t, 0) + "</text>";
      }
      if (!o.hero) s += '<text class="axis-title" x="' + x1 + '" y="' + (bottom + 29) + '" text-anchor="end">Position du foret · mm</text>';
      s += '<line class="crosshair" x1="-10" x2="-10" y1="' + m.t + '" y2="' + bottom + '"/>';
      s += '<rect class="hit" x="' + x0 + '" y="' + m.t + '" width="' + (x1 - x0) + '" height="' + (bottom - m.t) + '" fill="transparent"/>';
      s += "</svg>";
      if (o.hover && !o.hero) s += '<div class="ar-tooltip" role="presentation"></div>';
      el.innerHTML = s;
      geom = { W: W, H: H, x0: x0, x1: x1, xmax: xmax, sx: sx, m: m, bottom: bottom, scales: scales };
      if (state.reveal != null) setReveal(state.reveal);
      if (o.hover && !o.hero) bindHover();
    }

    function bindHover() {
      var svg = el.querySelector("svg"), hit = el.querySelector(".hit"), tip = el.querySelector(".ar-tooltip");
      var cross = el.querySelector(".crosshair");
      function move(e) {
        var r = svg.getBoundingClientRect();
        var px = (e.clientX - r.left) * (geom.W / r.width);
        var v = ((px - geom.x0) / (geom.x1 - geom.x0)) * geom.xmax;
        var i = nearest(data.position, v);
        var x = geom.sx(data.position[i]);
        cross.setAttribute("x1", x); cross.setAttribute("x2", x);
        var rows = "";
        o.panels.forEach(function (key) {
          var dot = el.querySelector('.hover-dot[data-key="' + key + '"]');
          dot.setAttribute("cx", x); dot.setAttribute("cy", geom.scales[key].sy(data[key][i]));
          rows += '<div class="ar-tooltip__row"><span><i style="background:var(--' + SIGNALS[key].color + ')"></i>' + SIGNALS[key].short + "</span><b>" + fmt(data[key][i], key === "thrust" ? 2 : 1) + " " + SIGNALS[key].unit + "</b></div>";
          if (data.reference) rows += '<div class="ar-tooltip__row"><span>Référence (IA)</span><b>' + fmt(data.reference[key][i], key === "thrust" ? 2 : 1) + " " + SIGNALS[key].unit + "</b></div>";
        });
        var L = layerAt(data.layers || [], data.position[i]);
        tip.innerHTML = '<div class="ar-tooltip__head">' + fmt(data.position[i], 2) + " mm · " + (L ? MATERIALS[L.mat] : "hors matière") + "</div>" + rows;
        var left = (x / geom.W) * r.width;
        left = Math.max(80, Math.min(r.width - 80, left));
        tip.style.left = left + "px";
        tip.style.top = (geom.m.t / geom.H) * r.height + "px";
        el.classList.add("is-hover");
      }
      hit.addEventListener("pointermove", move);
      hit.addEventListener("pointerdown", move);
      hit.addEventListener("pointerleave", function () { el.classList.remove("is-hover"); });
    }

    function setReveal(xUntil) {
      var rect = el.querySelector("rect.reveal");
      if (!rect || !geom) return;
      var w = xUntil == null ? geom.W : geom.sx(Math.min(xUntil, geom.xmax));
      rect.setAttribute("width", Math.max(0, w).toFixed(1));
      el.querySelectorAll(".evt").forEach(function (g) {
        g.style.opacity = xUntil == null || parseFloat(g.getAttribute("data-x")) <= xUntil ? "" : "0";
      });
    }

    function draw(done) {
      var paths = el.querySelectorAll(".line, .hero-line");
      var dur = ms("dur-draw", el, 1800);
      var evts = el.querySelectorAll(".evt");
      if (reducedMotion()) { evts.forEach(function (g) { g.style.opacity = 1; }); if (done) done(); return; }
      paths.forEach(function (p) {
        if (p.classList.contains("line--ref")) return;
        var len = p.getTotalLength();
        p.style.strokeDasharray = len + " " + len;
        p.style.strokeDashoffset = len;
      });
      tween(dur, null, function (k) {
        paths.forEach(function (p) {
          if (p.classList.contains("line--ref")) return;
          var len = parseFloat(p.style.strokeDasharray);
          p.style.strokeDashoffset = (len * (1 - k)).toFixed(1);
        });
      }, function () {
        paths.forEach(function (p) { p.style.strokeDasharray = ""; p.style.strokeDashoffset = ""; });
        evts.forEach(function (g) { g.style.transition = "opacity " + ms("dur-base", el, 240) + "ms"; g.style.opacity = 1; });
        var sig = el.querySelector(".signal");
        if (sig) { sig.classList.remove("is-pulsing"); void sig.getBoundingClientRect(); sig.classList.add("is-pulsing"); }
        if (done) done();
      });
    }

    render();
    var ro = typeof ResizeObserver === "function" ? new ResizeObserver(function () {
      if (geom && Math.abs((el.clientWidth || 0) - geom.W) > 2) render();
    }) : null;
    if (ro) ro.observe(el);
    if (o.draw) requestAnimationFrame(function () { draw(o.onDone); });

    return {
      el: el,
      update: function (d, extra) { data = d; if (extra) Object.assign(o, extra); render(); },
      replay: function (done) { render(); requestAnimationFrame(function () { draw(done); }); },
      focus: function (i) {
        state.focus = i;
        el.querySelectorAll(".layer").forEach(function (g) {
          var on = i == null || String(i) === g.getAttribute("data-layer");
          g.classList.toggle("is-dim", !on);
        });
      },
      reveal: function (xUntil, animate) {
        var from = state.reveal == null ? geom.xmax : state.reveal;
        var to = xUntil == null ? geom.xmax : xUntil;
        state.reveal = to;
        if (!animate) { setReveal(to); return; }
        tween(ms("dur-slow", el, 480), easeInOut, function (k) { setReveal(from + (to - from) * k); });
      },
      destroy: function () { if (ro) ro.disconnect(); el.innerHTML = ""; }
    };
  }

  /* Tendance d'usure : un point par trou, médiane glissante, seuil, et projection IA en pointillés */
  function wearTrend(el, data, opts) {
    var o = Object.assign({ height: 260, hover: true }, opts || {});
    var geom = null;
    el.classList.add("ar-chart");
    function render() {
      var W = Math.max(280, Math.round(el.clientWidth || 640));
      var H = o.height;
      var m = { l: 44, r: 16, t: 30, b: 36 };
      var x0 = m.l, x1 = W - m.r, y0 = H - m.b, yt = m.t;
      var P = data.projection;
      var xmax = o.xmax || niceCeil(Math.max(data.holes[data.holes.length - 1], P ? P.holes[P.holes.length - 1] : 0));
      if (xmax > 200 && xmax < 250) xmax = 240;
      var vals = data.torque.concat(P ? P.hi : []).concat([data.threshold]);
      var ymin = o.ymin != null ? o.ymin : Math.floor(Math.min.apply(null, data.torque) * 2) / 2 - 0.5;
      var ymax = o.ymax != null ? o.ymax : Math.ceil(Math.max.apply(null, vals) * 2) / 2 + 0.25;
      var sx = function (v) { return x0 + (v / xmax) * (x1 - x0); };
      var sy = function (v) { return y0 - ((v - ymin) / (ymax - ymin)) * (y0 - yt); };
      var s = '<svg viewBox="0 0 ' + W + " " + H + '" height="' + H + '" role="img" aria-label="Couple moyen dans le titane selon le nombre de trous depuis le changement d\'outil, avec seuil et projection">';
      var stepY = (ymax - ymin) > 2 ? 1 : 0.5;
      for (var t = Math.ceil(ymin / stepY) * stepY; t <= ymax + 1e-9; t += stepY) {
        var y = sy(t).toFixed(1);
        s += '<line class="gridline" x1="' + x0 + '" x2="' + x1 + '" y1="' + y + '" y2="' + y + '"/>';
        s += '<text class="tick" x="' + (x0 - 6) + '" y="' + y + '" dy="0.32em" text-anchor="end">' + fmt(t, stepY < 1 ? 1 : 0) + "</text>";
      }
      s += '<text class="panel-title" x="' + x0 + '" y="' + (m.t - 14) + '">Couple moyen dans le titane · ' + data.unit + "</text>";
      s += '<line class="axisline" x1="' + x0 + '" x2="' + x1 + '" y1="' + y0 + '" y2="' + y0 + '"/>';
      var stepX = xmax >= 200 ? 40 : 20;
      for (var u = 0; u <= xmax + 1e-9; u += stepX) s += '<text class="tick" x="' + sx(u).toFixed(1) + '" y="' + (y0 + 14) + '" text-anchor="middle">' + fmt(u, 0) + "</text>";
      s += '<text class="axis-title" x="' + x1 + '" y="' + (y0 + 30) + '" text-anchor="end">Trous depuis le changement d\'outil</text>';
      /* Seuil */
      var ty = sy(data.threshold).toFixed(1);
      s += '<line class="threshold" x1="' + x0 + '" x2="' + x1 + '" y1="' + ty + '" y2="' + ty + '"/>';
      s += '<text class="threshold-label" x="' + (x0 + 6) + '" y="' + (sy(data.threshold) - 6).toFixed(1) + '">Seuil de changement ' + fmt(data.threshold, 1) + " " + data.unit + "</text>";
      /* Projection IA */
      if (P) {
        var band = "";
        for (var i = 0; i < P.holes.length; i++) band += (i ? "L" : "M") + sx(P.holes[i]).toFixed(1) + " " + sy(P.hi[i]).toFixed(1);
        for (var j = P.holes.length - 1; j >= 0; j--) band += "L" + sx(P.holes[j]).toFixed(1) + " " + sy(P.lo[j]).toFixed(1);
        s += '<path class="band-est" style="fill:var(--sig-torque)" d="' + band + 'Z"/>';
        s += '<path class="line line--est" style="stroke:var(--sig-torque)" d="' + pathOf(P.holes, P.value, sx, sy) + '"/>';
        var cx = sx(P.cross).toFixed(1);
        s += '<line class="event" x1="' + cx + '" x2="' + cx + '" y1="' + yt + '" y2="' + y0 + '"/>';
        var right = sx(P.cross) > x1 - 170;
        s += '<text class="event-label" x="' + (right ? sx(P.cross) - 6 : sx(P.cross) + 6).toFixed(1) + '" y="' + (yt + 12) + '" text-anchor="' + (right ? "end" : "start") + '">IA · estimé : ' + P.cross + " trous ± " + P.margin + "</text>";
      }
      /* Médiane glissante sur 5 points */
      var med = data.torque.map(function (v, k) {
        var w = data.torque.slice(Math.max(0, k - 2), k + 3).slice().sort(function (a, b) { return a - b; });
        return w[w.length >> 1];
      });
      s += '<path class="line" style="stroke:var(--sig-torque)" d="' + pathOf(data.holes, med, sx, sy) + '"/>';
      data.holes.forEach(function (h, k) {
        var lastPt = k === data.holes.length - 1;
        s += '<circle class="dot" r="' + (lastPt ? 5 : 3.5) + '" cx="' + sx(h).toFixed(1) + '" cy="' + sy(data.torque[k]).toFixed(1) + '" style="fill:var(--sig-torque);opacity:' + (lastPt ? 1 : 0.55) + '"/>';
      });
      var lx = sx(data.holes[data.holes.length - 1]), ly = sy(data.torque[data.torque.length - 1]);
      s += '<text class="event-label" x="' + (lx - 8).toFixed(1) + '" y="' + (Math.min(ly - 10, sy(data.threshold) - 8)).toFixed(1) + '" text-anchor="end">Aujourd\'hui · ' + fmt(data.torque[data.torque.length - 1], 2) + " " + data.unit + "</text>";
      s += '<line class="crosshair" x1="-10" x2="-10" y1="' + yt + '" y2="' + y0 + '"/><circle class="hover-dot" r="5" cx="-10" cy="-10" style="fill:var(--sig-torque)"/>';
      s += '<rect class="hit" x="' + x0 + '" y="' + yt + '" width="' + (x1 - x0) + '" height="' + (y0 - yt) + '" fill="transparent"/></svg>';
      if (o.hover) s += '<div class="ar-tooltip" role="presentation"></div>';
      el.innerHTML = s;
      geom = { W: W, H: H, x0: x0, x1: x1, xmax: xmax, sx: sx, sy: sy, yt: yt };
      if (o.hover) bind();
    }
    function bind() {
      var svg = el.querySelector("svg"), hit = el.querySelector(".hit"), tip = el.querySelector(".ar-tooltip");
      var cross = el.querySelector(".crosshair"), dot = el.querySelector(".hover-dot");
      var P = data.projection;
      hit.addEventListener("pointermove", function (e) {
        var r = svg.getBoundingClientRect();
        var px = (e.clientX - r.left) * (geom.W / r.width);
        var v = ((px - geom.x0) / (geom.x1 - geom.x0)) * geom.xmax;
        var html, x, y;
        if (P && v > data.holes[data.holes.length - 1]) {
          var k = nearest(P.holes, v);
          x = geom.sx(P.holes[k]); y = geom.sy(P.value[k]);
          html = '<div class="ar-tooltip__head">Trou ' + P.holes[k] + " · estimé</div>" +
            '<div class="ar-tooltip__row"><span><i style="background:var(--sig-torque)"></i>Couple projeté</span><b>' + fmt(P.value[k], 2) + " " + data.unit + "</b></div>" +
            '<div class="ar-tooltip__row"><span>Intervalle</span><b>' + fmt(P.lo[k], 2) + " à " + fmt(P.hi[k], 2) + "</b></div>";
        } else {
          var i = nearest(data.holes, v);
          x = geom.sx(data.holes[i]); y = geom.sy(data.torque[i]);
          html = '<div class="ar-tooltip__head">Trou ' + data.holes[i] + " · mesuré</div>" +
            '<div class="ar-tooltip__row"><span><i style="background:var(--sig-torque)"></i>Couple moyen</span><b>' + fmt(data.torque[i], 2) + " " + data.unit + "</b></div>";
        }
        cross.setAttribute("x1", x); cross.setAttribute("x2", x); dot.setAttribute("cx", x); dot.setAttribute("cy", y);
        tip.innerHTML = html;
        tip.style.left = Math.max(80, Math.min(r.width - 80, (x / geom.W) * r.width)) + "px";
        tip.style.top = (y / geom.H) * r.height + "px";
        el.classList.add("is-hover");
      });
      hit.addEventListener("pointerleave", function () { el.classList.remove("is-hover"); });
    }
    render();
    var ro = typeof ResizeObserver === "function" ? new ResizeObserver(function () {
      if (geom && Math.abs((el.clientWidth || 0) - geom.W) > 2) render();
    }) : null;
    if (ro) ro.observe(el);
    return { el: el, update: function (d) { data = d; render(); }, destroy: function () { if (ro) ro.disconnect(); el.innerHTML = ""; } };
  }

  /* Sparkline de KpiTile : trait 1,5, aire légère, dernier point marqué */
  function sparkline(el, values, opts) {
    var o = Object.assign({ color: "s1", height: 28 }, opts || {});
    var W = Math.max(80, Math.round(el.clientWidth || 160)), H = o.height;
    var mn = Math.min.apply(null, values), mx = Math.max.apply(null, values), span = mx - mn || 1;
    var sx = function (i) { return 2 + (i / (values.length - 1)) * (W - 6); };
    var sy = function (v) { return H - 3 - ((v - mn) / span) * (H - 7); };
    var d = values.map(function (v, i) { return (i ? "L" : "M") + sx(i).toFixed(1) + " " + sy(v).toFixed(1); }).join("");
    var lx = sx(values.length - 1), ly = sy(values[values.length - 1]);
    el.classList.add("ar-chart");
    el.innerHTML = '<svg viewBox="0 0 ' + W + " " + H + '" height="' + H + '" aria-hidden="true">' +
      '<path d="' + d + "L" + lx.toFixed(1) + " " + H + "L" + sx(0).toFixed(1) + " " + H + 'Z" style="fill:var(--' + o.color + ');opacity:.12"/>' +
      '<path d="' + d + '" style="fill:none;stroke:var(--' + o.color + ');stroke-width:1.5;stroke-linejoin:round"/>' +
      '<circle cx="' + lx.toFixed(1) + '" cy="' + ly.toFixed(1) + '" r="3" style="fill:var(--' + o.color + ')"/></svg>';
  }

  /* Thème Plotly pour l'app (Plotly 2.35) : couleurs lues dans les jetons au moment de l'appel.
     Rappeler Plotly.relayout(div, Arion.plotly.layout()) après un changement de thème. */
  function merge(a, b) {
    var out = Array.isArray(a) ? a.slice() : Object.assign({}, a);
    Object.keys(b || {}).forEach(function (k) {
      var v = b[k];
      out[k] = v && typeof v === "object" && !Array.isArray(v) && a && typeof a[k] === "object" ? merge(a[k], v) : v;
    });
    return out;
  }
  function plotlyAxis(overrides, el) {
    var c = function (n) { return rgba(css(n, el)); };
    var sans = css("font-sans", el) || "Instrument Sans, sans-serif";
    var mono = css("font-mono", el) || "JetBrains Mono, monospace";
    return merge({
      gridcolor: c("grid"), linecolor: c("axis"), zeroline: false, ticks: "", showline: true,
      tickfont: { family: mono, size: 10.5, color: c("muted") },
      title: { font: { family: sans, size: 11, color: c("text-2") }, standoff: 8 },
      automargin: true
    }, overrides || {});
  }
  var plotly = {
    /* Axe au style Arion, pour xaxis2, yaxis2… : yaxis2: Arion.plotly.axis({ title: { text: 'Poussée · A' } }) */
    axis: plotlyAxis,
    layout: function (overrides, el) {
      var c = function (n) { return rgba(css(n, el)); };
      var sans = css("font-sans", el) || "Instrument Sans, sans-serif";
      var mono = css("font-mono", el) || "JetBrains Mono, monospace";
      return merge({
        font: { family: sans, size: 12, color: c("text-2") },
        paper_bgcolor: "rgba(0,0,0,0)", plot_bgcolor: "rgba(0,0,0,0)",
        colorway: ["s1", "s2", "s3", "s4", "s5", "s6"].map(c),
        separators: ",\u202f",
        margin: { l: 48, r: 12, t: 28, b: 40 },
        xaxis: plotlyAxis(null, el), yaxis: plotlyAxis(null, el),
        hoverlabel: { bgcolor: c("surface"), bordercolor: c("border-strong"), font: { family: mono, size: 12, color: c("text") } },
        legend: { orientation: "h", x: 0, xanchor: "left", y: 1.02, yanchor: "bottom", bgcolor: "rgba(0,0,0,0)", font: { family: sans, size: 12, color: c("text-2") } }
      }, overrides || {});
    },
    config: { displaylogo: false, responsive: true, modeBarButtonsToRemove: ["lasso2d", "select2d", "autoScale2d", "toggleSpikelines"] },
    /* Une série calculée par un modèle : même couleur, trait en tirets, nom suffixé « estimé » */
    estimated: function (trace) {
      var t = Object.assign({}, trace);
      t.line = Object.assign({ width: 2 }, trace.line || {}, { dash: "dash" });
      t.name = (trace.name || "Série") + " · estimé";
      return t;
    },
    signal: function (key, el) { return rgba(css(SIGNALS[key] ? SIGNALS[key].color : key, el)); },
    /* Bandes de couches (teinte par matière + étiquette ; les hachures restent au SVG) */
    layers: function (layers, el) {
      var shapes = [], annotations = [];
      var mono = css("font-mono", el) || "JetBrains Mono, monospace";
      layers.forEach(function (L) {
        shapes.push({ type: "rect", xref: "x", yref: "paper", x0: L.from, x1: L.to, y0: 0, y1: 1, layer: "below", line: { width: 0 }, fillcolor: rgba(css("layer-" + L.mat, el)) });
        annotations.push({ xref: "x", yref: "paper", x: L.from, y: 1, xanchor: "left", yanchor: "bottom", showarrow: false, text: MATERIALS[L.mat], font: { family: mono, size: 10, color: rgba(css("text-2", el)) } });
      });
      return { shapes: shapes, annotations: annotations };
    },
    events: function (events, el) {
      var shapes = [], annotations = [];
      var mono = css("font-mono", el) || "JetBrains Mono, monospace";
      events.forEach(function (ev) {
        shapes.push({ type: "line", xref: "x", yref: "paper", x0: ev.x, x1: ev.x, y0: 0, y1: 1, line: { color: rgba(css("text-2", el)), width: 1, dash: "dot" } });
        annotations.push({ xref: "x", yref: "paper", x: ev.x, y: 1, xanchor: "left", yanchor: "top", xshift: 4, showarrow: false, text: ev.label, font: { family: mono, size: 10.5, color: rgba(css("text-2", el)) } });
      });
      return { shapes: shapes, annotations: annotations };
    },
    anomaly: function (a, el) {
      return {
        shapes: [{ type: "rect", xref: "x", yref: "paper", x0: a.from, x1: a.to, y0: 0, y1: 1, layer: "below", line: { width: 0 }, fillcolor: rgba(css("signal-soft", el)) },
          { type: "line", xref: "x", yref: "paper", x0: a.from, x1: a.to, y0: 1, y1: 1, line: { color: rgba(css("signal", el)), width: 1.5 } }],
        annotations: [{ xref: "x", yref: "paper", x: a.from, y: 1, xanchor: "left", yanchor: "top", xshift: 4, yshift: -4, showarrow: false, text: a.label, font: { size: 11, color: rgba(css("signal-ink", el)) } }]
      };
    }
  };

  var Arion = {
    version: "1.0.0",
    icon: icon, icons: Object.keys(ICONS), mark: mark,
    css: css, ms: ms, fmt: fmt, materials: MATERIALS,
    setTheme: setTheme, initTheme: initTheme, reducedMotion: reducedMotion,
    sampleCycle: sampleCycle, sampleWear: sampleWear,
    cycleTrace: cycleTrace, wearTrend: wearTrend, sparkline: sparkline,
    plotly: plotly
  };
  window.Arion = Object.assign(window.Arion || {}, Arion);
})();
