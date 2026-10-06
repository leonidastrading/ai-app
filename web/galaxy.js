/*
 * UAI animated galaxy — drop-in for any web page or Electron renderer.
 *
 * Usage:
 *   <script src="galaxy.js"></script>
 *   UAIGalaxy.mountAll('.galaxy');          // every matching element gets a live galaxy
 *   const g = UAIGalaxy.mount(element);     // or one element; g.destroy() to remove
 *
 * The galaxy fills its element (make the element square; it is clipped to a circle).
 * No dependencies, no image files, works under a strict CSP (script-src 'self').
 * Respects prefers-reduced-motion (draws one still frame) and pauses when off-screen.
 */
(function (global) {
  'use strict';

  var COLORS = ['#ff7ab8', '#b28cff', '#7fd6ff', '#ffffff', '#ffb3d1']; // pink, lavender, aqua, white, blush
  var DOTS = 260;          // number of stars in the spiral
  var SPIN = 0.24;         // radians per second at the core (0.004 per frame at 60 fps)
  var reduceMotion = global.matchMedia && global.matchMedia('(prefers-reduced-motion: reduce)').matches;

  function makeStars() {
    var stars = [];
    for (var i = 0; i < DOTS; i++) {
      var arm = i % 2;                 // two spiral arms, half a turn apart
      var t = Math.random();           // 0 = core, 1 = rim
      stars.push({
        a: arm * Math.PI + t * 5.5 + (Math.random() - 0.5) * 0.6, // angle along the arm, with scatter
        r: t * 0.82,                   // distance from center, as a fraction of the radius
        s: Math.random() * 1.6 + 0.6,  // dot size (scaled to the galaxy's size when drawn)
        c: COLORS[(Math.random() * COLORS.length) | 0]
      });
    }
    return stars;
  }

  function mount(el) {
    if (!el || el.__uaiGalaxy) return el && el.__uaiGalaxy;
    var canvas = document.createElement('canvas');
    canvas.setAttribute('aria-hidden', 'true');
    canvas.style.cssText = 'display:block;width:100%;height:100%;border-radius:50%';
    el.innerHTML = '';
    el.appendChild(canvas);

    var g = canvas.getContext('2d');
    var stars = makeStars();
    var W = 0, raf = 0, start = performance.now(), visible = true;

    function resize() {
      var css = Math.max(1, Math.min(el.clientWidth, el.clientHeight) || el.clientWidth || 48);
      var dpr = Math.min(global.devicePixelRatio || 1, 3);
      W = Math.round(css * dpr);
      canvas.width = canvas.height = W;
      draw((performance.now() - start) / 1000);
    }

    function draw(seconds) {
      if (!W) return;
      var C = W / 2, rot = seconds * SPIN;
      g.clearRect(0, 0, W, W);

      // Deep-space disc.
      var bg = g.createRadialGradient(C, C, 0, C, C, C);
      bg.addColorStop(0, '#3b2f9e'); bg.addColorStop(0.55, '#17145c'); bg.addColorStop(1, '#0a0930');
      g.fillStyle = bg; g.beginPath(); g.arc(C, C, C, 0, 6.283); g.fill();

      // Stars. Inner stars orbit faster than outer ones (rot * (1.3 - r)),
      // so the arms slowly wind up into a swirl, like a real galaxy.
      g.globalAlpha = 0.85;
      for (var i = 0; i < stars.length; i++) {
        var p = stars[i], r = p.r * C, a = p.a + rot * (1.3 - p.r);
        g.fillStyle = p.c; g.beginPath();
        g.arc(C + Math.cos(a) * r, C + Math.sin(a) * r, p.s * W / 176, 0, 6.283);
        g.fill();
      }

      // Glowing core.
      var core = g.createRadialGradient(C, C, 0, C, C, C * 0.28);
      core.addColorStop(0, 'rgba(255,220,240,.95)'); core.addColorStop(1, 'rgba(255,120,190,0)');
      g.globalAlpha = 1; g.fillStyle = core; g.beginPath(); g.arc(C, C, C * 0.28, 0, 6.283); g.fill();
    }

    function loop(now) {
      draw((now - start) / 1000);
      raf = (!reduceMotion && visible) ? requestAnimationFrame(loop) : 0;
    }

    var ro = global.ResizeObserver ? new ResizeObserver(resize) : null;
    if (ro) ro.observe(el);
    var io = global.IntersectionObserver ? new IntersectionObserver(function (e) {
      visible = e[0].isIntersecting;
      if (visible && !raf && !reduceMotion) raf = requestAnimationFrame(loop);
    }) : null;
    if (io) io.observe(el);

    resize();
    if (!reduceMotion) raf = requestAnimationFrame(loop);

    var api = {
      destroy: function () {
        cancelAnimationFrame(raf); if (ro) ro.disconnect(); if (io) io.disconnect();
        el.innerHTML = ''; delete el.__uaiGalaxy;
      }
    };
    el.__uaiGalaxy = api;
    return api;
  }

  function mountAll(selector) {
    var list = document.querySelectorAll(selector || '.galaxy'), out = [];
    for (var i = 0; i < list.length; i++) out.push(mount(list[i]));
    return out;
  }

  global.UAIGalaxy = { mount: mount, mountAll: mountAll };
})(window);
