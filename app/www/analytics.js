// Google Analytics, shared with danielburkhalter.dev and the other apps.
// Only the live hosts report, so local runs stay out of the numbers. The
// path is fixed because both shinyapps.io and shinylive run the app inside
// an iframe with a generated URL. The gtag.js loader itself is a separate
// async <script> in app.R.
window.dataLayer = window.dataLayer || [];
function gtag(){dataLayer.push(arguments);}
if (['danielburkhalter.dev', 'danielburkhalter.shinyapps.io']
      .includes(location.hostname)) {
  gtag('js', new Date());
  gtag('config', 'G-3HK7FW9Y6N', {
    page_location: location.origin + '/bank-check/'
  });
}
