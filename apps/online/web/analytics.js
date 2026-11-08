// Analytics for the ordering site, off until the guest agrees.
//
// Nothing here runs until the site calls siteAnalytics.load(), which it only
// does when a measurement ID was built in (--dart-define=
// ANALYTICS_MEASUREMENT_ID=G-...) and the guest accepted analytics cookies.
// Firebase Analytics on the web is this same Google tag, so a Firebase web
// app's measurement ID works here. Consent mode starts denied.
(function () {
  var loaded = false;
  window.dataLayer = window.dataLayer || [];
  function gtag() { window.dataLayer.push(arguments); }
  window.siteAnalytics = {
    load: function (measurementId) {
      if (loaded || !/^G-[A-Z0-9]+$/.test(measurementId)) return;
      loaded = true;
      window.gtag = gtag;
      gtag('consent', 'default', {
        analytics_storage: 'denied',
        ad_storage: 'denied',
        ad_user_data: 'denied',
        ad_personalization: 'denied',
      });
      gtag('js', new Date());
      // The site sends its own page views, one per screen.
      gtag('config', measurementId, { send_page_view: false });
      var s = document.createElement('script');
      s.async = true;
      s.src = 'https://www.googletagmanager.com/gtag/js?id=' + encodeURIComponent(measurementId);
      document.head.appendChild(s);
    },
    consent: function (granted) {
      if (loaded) gtag('consent', 'update', { analytics_storage: granted ? 'granted' : 'denied' });
    },
    event: function (name, params) {
      if (loaded) gtag('event', name, params || {});
    },
  };
})();
