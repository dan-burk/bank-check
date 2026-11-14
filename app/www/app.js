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
