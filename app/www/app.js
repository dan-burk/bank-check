// Client-side behavior for Bank Check. Loaded from <head> after Shiny and
// jQuery, without defer/async, so both globals exist when this runs.

// Fetch overlay: spinner plus rotating jokes while a bank's history
// downloads. The rotation is client-side on purpose: during the fetch the
// R process is blocked (fully so under webR, where R runs single-threaded
// in a worker), so the server cannot push updates until the download
// finishes. R only toggles the overlay via session$sendCustomMessage.
// The same jokes appear in pages/loading.html; keep the two in sync.
(function() {
  var jokes = [
    'Why did the banker quit? She lost interest.',
    'I asked the bank to check my balance. They pushed me over.',
    'Why are piggy banks so wise? Full of common cents.',
    'Old bankers never die. They just lose their balance.',
    'My bank flagged suspicious activity. Apparently saving was out of character.',
    'The safest place for cash is a snow bank. Frozen assets.',
    'Where do fish keep their money? In the river bank.',
    'The loan officer married the teller. Now it is a joint account.',
    'Quarterly filings since 1984. Good things come to those who wait.',
    'Dad, are we rich? No son, we are FDIC insured.'
  ];
  var timer = null;
  Shiny.addCustomMessageHandler('fetch_overlay', function(msg) {
    var el = document.getElementById('fetch_overlay');
    var jokeEl = el.querySelector('.joke');
    if (msg.show) {
      var i = Math.floor(Math.random() * jokes.length);
      jokeEl.textContent = jokes[i];
      el.style.display = 'flex';
      if (timer) clearInterval(timer);
      timer = setInterval(function() {
        i = (i + 1) % jokes.length;
        jokeEl.textContent = jokes[i];
      }, 4000);
    } else {
      el.style.display = 'none';
      if (timer) { clearInterval(timer); timer = null; }
    }
  });
})();

// Boot overlay: covers the half-built page from first paint until the
// server's first flush finishes (first shiny:idle). On shinylive, the outer
// loading page (pages/loading.html) waits for this element to be removed
// before fading out. The 60s fallback keeps a stalled or errored session
// from hiding the app forever.
(function() {
  var done = false;
  function hide() {
    if (done) return;
    done = true;
    var el = document.getElementById('boot_overlay');
    if (!el) return;
    el.style.opacity = '0';
    setTimeout(function() { el.remove(); }, 500);
  }
  // Short delay: plotly draws client-side just after the values land
  $(document).one('shiny:idle', function() { setTimeout(hide, 300); });
  setTimeout(hide, 60000);
})();

// QoQ/YoY toggle: disabled while banks are compared (the statements then
// show one column per bank and no change column). Re-applied whenever the
// Overview card re-renders, since the radio buttons are rebuilt then.
(function() {
  var on = true;
  function apply() {
    var group = document.getElementById('fs_cmp');
    if (!group) return;
    group.querySelectorAll('input').forEach(function(el) { el.disabled = !on; });
    group.style.opacity = on ? '' : '0.45';
  }
  Shiny.addCustomMessageHandler('fs_cmp_enabled', function(msg) {
    on = msg.on;
    apply();
  });
  $(document).on('shiny:value', function(e) {
    if (e.name === 'overview_grid') setTimeout(apply, 0);
  });
})();

// Statement links ("Asset Quality", "Liquidity & Funding", ...): open that
// top-level tab by clicking its navbar link (bslib tags each one with
// data-value = the tab title), then scroll to the top of the page.
$(document).on('click', '.fs-tab-link', function(e) {
  e.preventDefault();
  var tab = this.getAttribute('data-tab');
  var links = document.querySelectorAll('.navbar .nav-link[data-value]');
  for (var i = 0; i < links.length; i++) {
    if (links[i].getAttribute('data-value') === tab) {
      links[i].click();
      window.scrollTo(0, 0);
      return;
    }
  }
});

// Industry loader: cartoon shown above the Industry tab while its two
// history charts build (all R work, so this runs client-side like the fetch
// overlay). First open: shown at once, kept up >= 2.5 s so the joke lands.
// $/% toggles: shown only if still busy after 0.6 s. Hidden once both
// charts sent a value or error since it showed; a 1 s check (nothing
// recalculating, both charts drawn before) and a 60 s cap mean it can
// never stick.
(function() {
  var PLOTS = ['ind_bs_plot', 'ind_is_plot'];
  var EMOJI = ['😫', '😳', '😱', '😵‍💫', '😵'];
  var QUIPS = [
    'Counting 17,949 banks by hand…',
    'Bribing the FDIC intern with donuts…',
    'Faxing 1984 for its call reports…',
    'Rewinding the microfiche…',
    'Asking Savings & Loan what happened…',
    'Converting thousands to thousands. Of thousands.',
    'Reconciling a quarter that was restated twice…',
    'Explaining JOIN to a 1984 mainframe…',
    'Adding up $24 trillion. Carry the one…',
    'Paging past the 10,000-row limit. Again.'
  ];
  var SQL = 'SELECT * FROM all_banks WHERE year >= 1984;';
  var SVG = '<svg viewBox="0 0 120 120">' +
    '<rect x="8" y="104" width="104" height="6" rx="2" fill="#ADB5BD"/>' +
    '<path d="M34 104 Q36 74 60 72 Q84 74 86 104Z" fill="#2C5F8A"/>' +
    '<circle class="face" cx="60" cy="48" r="20" fill="#FAD7C0"/>' +
    '<path d="M41 42 Q44 24 60 26 Q76 24 79 42 Q70 34 60 35 Q50 34 41 42Z" fill="#5B6670"/>' +
    '<circle cx="53" cy="49" r="2.3" fill="#1F2933"/><circle cx="67" cy="49" r="2.3" fill="#1F2933"/>' +
    '<path d="M47 44 l9 -3 M73 44 l-9 -3" stroke="#1F2933" stroke-width="1.6" stroke-linecap="round"/>' +
    '<path class="mouth" d="M54 59 Q60 56 66 59" stroke="#1F2933" stroke-width="1.8" fill="none" stroke-linecap="round"/>' +
    '<ellipse class="drop d1" cx="80" cy="38" rx="3.2" ry="4.8"/>' +
    '<ellipse class="drop d2" cx="40" cy="44" rx="3.2" ry="4.8"/>' +
    '<ellipse class="drop d3" cx="76" cy="28" rx="2.8" ry="4.2"/>' +
    '<g class="arms" stroke="#2C5F8A" stroke-width="7" stroke-linecap="round">' +
    '<path d="M40 88 L50 98"/><path d="M80 88 L70 98"/></g>' +
    '<path d="M28 104 L36 86 H84 L92 104Z" fill="#DEE2E6" stroke="#ADB5BD"/>' +
    '<circle cx="60" cy="95" r="2.2" fill="#ADB5BD"/></svg>';

  var drawn = {};          // chart id -> has ever received a value
  var pending = {};        // chart id -> still owed a value since show
  var shownAt = 0, minMs = 0, delayT = null, hideT = null, timers = [];
  var pick = function(a) { return a[Math.floor(Math.random() * a.length)]; };
  var root = function() { return document.getElementById('ind_loader'); };
  var busy = function() {
    return document.querySelectorAll('#ind_bs_plot.recalculating,#ind_is_plot.recalculating').length > 0;
  };

  function animate(el, again) {
    el.className = 'on';
    el.innerHTML = '<div class="headline"></div><div class="stage" aria-hidden="true">' +
      SVG + '<div class="term"><div class="cmd"></div><div class="rows"></div></div></div>' +
      '<div class="count">0 rows</div><div class="joke"></div>';
    var find = function(s) { return el.querySelector(s); };
    var reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var n = 0, i = 0, q = Math.floor(Math.random() * QUIPS.length);
    find('.headline').textContent = (again ? 'Again?! Fine. Re-pulling ALL data since 1984. '
      : "Really? You're going to have me pull ALL data since 1984? ") + pick(EMOJI);
    find('.joke').textContent = QUIPS[q];
    timers.push(setInterval(function() {
      q = (q + 1) % QUIPS.length;
      find('.joke').textContent = QUIPS[q] + ' ' + pick(EMOJI);
    }, 2600));
    function row() {   // fake call-report row: cert | quarter end | assets ($000)
      var y = 1984 + Math.floor(Math.random() * 42);
      return ('     ' + (1 + Math.floor(Math.random() * 59999))).slice(-5) + ' | ' + y +
        ['0331', '0630', '0930', '1231'][n % 4] + ' | ' +
        Math.floor(Math.random() * 9e6).toLocaleString('en-US');
    }
    function run() {
      el.classList.add('run');
      find('.mouth').setAttribute('d', 'M54 60 Q60 60 66 60');
      var buf = [];
      timers.push(setInterval(function() {
        n += Math.floor(4000 + Math.random() * 9000 + n / 40);   // it's getting worse
        find('.count').textContent = n.toLocaleString('en-US') + ' rows…';
        if (!reduce) { buf.push(row(), row()); buf = buf.slice(-7); find('.rows').textContent = buf.join('\n'); }
        if (n > 4e5) el.classList.add('p2');
        if (n > 1.2e6) { el.classList.add('p3'); find('.mouth').setAttribute('d', 'M54 61 Q60 57 66 61'); }
      }, reduce ? 600 : 70));
    }
    if (reduce) { find('.cmd').textContent = SQL; run(); return; }
    var typing = setInterval(function() {
      find('.cmd').textContent = SQL.slice(0, ++i);
      if (i >= SQL.length) { clearInterval(typing); timers.push(setTimeout(run, 350)); }
    }, 25);   // fast enough that rows scroll before the 2.5 s minimum
    timers.push(typing);
  }

  function show(again) {
    delayT = null;
    var el = root();
    if (!el || shownAt) return;
    shownAt = Date.now(); minMs = again ? 1200 : 2500;
    PLOTS.forEach(function(id) { pending[id] = true; });
    animate(el, again);
  }
  function stop() {
    timers.forEach(function(t) { clearInterval(t); clearTimeout(t); });
    timers = []; hideT = null; shownAt = 0;
    var el = root();
    if (el) { el.className = ''; el.innerHTML = ''; }
  }
  function maybeHide() {
    if (!shownAt || hideT) return;
    var waited = Date.now() - shownAt;
    if (waited > 60000) return stop();
    if (PLOTS.some(function(id) { return pending[id]; })) return;
    hideT = setTimeout(stop, Math.max(300, minMs - waited));   // 300 ms: plotly draws
  }

  // First open of the tab: show before the server even starts
  $(document).on('show.bs.tab', function(e) {
    if (e.target.getAttribute('data-value') === 'Industry' &&
        !PLOTS.every(function(id) { return drawn[id]; })) show(false);
  });
  $(document).on('shiny:recalculating', function(e) {
    var id = e.target.id;
    if (PLOTS.indexOf(id) < 0) return;
    pending[id] = true;
    if (shownAt || delayT) return;
    if (!drawn[id]) show(false);
    else delayT = setTimeout(function() { if (busy()) show(true); else delayT = null; }, 600);
  });
  $(document).on('shiny:value shiny:error', function(e) {
    if (PLOTS.indexOf(e.name) < 0) return;
    drawn[e.name] = true;
    pending[e.name] = false;
    maybeHide();
  });
  setInterval(function() {   // failsafe
    if (shownAt && !busy() && PLOTS.every(function(id) { return drawn[id]; })) {
      PLOTS.forEach(function(id) { pending[id] = false; });
    }
    maybeHide();
  }, 1000);
})();
