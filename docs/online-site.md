# Ordering site: launch checklist

The public ordering site (`apps/online`) against a standard "is this site
real" list. The other apps (POS, kitchen display, manager, admin) are tools
for staff behind sign-in, so these items don't apply to them.

There is no marketing or landing site for the product itself yet. The home
page (`/`) only tells guests to use their restaurant's link. A product
marketing site is a separate piece of work.

| # | Item | Where |
| --- | --- | --- |
| 1 | Custom 404 | `NotFoundScreen` for unknown stores and paths; the `site` Function also answers those with HTTP 404 and `noindex` |
| 2 | Call to action above the fold | Store header: name, pickup time, address, phone and **Start your order** |
| 3 | Meta title per page | Server: `functions/src/site/seo.ts` (`pageFor`). In the app: `SitePage` sets `document.title` on every screen |
| 4 | Meta description per page | Same two places. Store pages say what, where and how fast, clipped to 160 characters |
| 5 | Open Graph image | `web/og-image.png` (1200×630), with `og:image:alt`, plus `twitter:card` |
| 6 | Favicon set | `favicon.ico` (16/32/48), `favicon.svg`, `favicon.png`, `icons/apple-touch-icon.png` (180), manifest icons 192/512 and maskable |
| 7 | robots.txt | Served by the `site` Function so it can name the sitemap's full address. Blocks `/*/order/` (private order pages) |
| 8 | sitemap.xml | The `site` Function: home, legal pages and every store taking online orders |
| 9 | Alt text on every image | Every icon has a `semanticLabel` or a tooltip; decorative ones are excluded. No menu photos are shown yet; when they are, use the item name as the label |
| 10 | Mobile breakpoints | `compactWidth` (600) in `site_chrome.dart`: tighter padding on phones, content capped at 560 to 720 wide on desktops. Tests run the store, checkout, thank-you, legal and 404 pages at 320×640 and fail on any overflow |
| 11 | Sticky mobile CTA | **View order** stays at the bottom of the menu once the cart has something; **Place order** stays at the bottom of checkout |
| 12 | Loading states | Spinner in `index.html` until Flutter draws, then "Loading the menu…", "Checking on your order…", and a spinner in the order button while placing |
| 13 | Form error states | Name required; phone and email optional but checked; errors appear under each field and update as the guest types; a banner above the order button for those and for server errors. Retry buttons when the menu or an order fails to load |
| 14 | Thank-you page | The order page after placing: "Thank you for your order!", the number to listen for, where to pick up (address and phone), progress, and **Order something else** |
| 15 | Privacy policy | `/privacy` and `/<store>/privacy`. **Draft** for counsel (PIPEDA, Quebec Law 25 note). Blanks in [brackets] |
| 16 | Terms page | `/terms` and `/<store>/terms`. **Draft** for counsel |
| 17 | Cookie banner | Shown only when analytics is built in. Accept and Decline are equally easy; the choice is stored in the browser; **Cookie settings** in the footer reopens it |
| 18 | Analytics | `ConsentGatedAnalytics` sends nothing, and loads no script, until the guest accepts. The provider is behind `AnalyticsSink`; `GoogleTagSink` works with a Firebase Analytics or GA4 web measurement ID. No ID is committed |
| 19 | Real contact address | The location's own `address` (entered when the location is created) and the phone and email managers set in the manager app's Online tab. Nothing is invented: a store with no address shows none, and the manager app says so |

## How pages reach crawlers

Flutter draws pages in the browser, so crawlers and link previews (which
often don't run JavaScript) would see one generic page. The site now uses
clean paths (`/maple-cambridge`, not `/#/maple-cambridge`), and Firebase
Hosting (`firebase.json`) sends every path that isn't a built file to the
`site` Function. It reads the built `index.html` from `ORDERING_SITE_URL`,
swaps the tags between `<!--seo:start-->` and `<!--seo:end-->` for that
page's, and answers with the right status.

The home page `/` is served as the static `index.html`, so its share image
link is relative. Fine for now; give it the same treatment if the home page
becomes a real landing page.

Store web addresses can't be the site's own paths (`privacy`, `terms`,
`sitemap` and others in `RESERVED_SLUGS`).

## Before launch (Maaz)

- Counsel reviews `apps/online/lib/src/legal.dart`, fills the [bracketed]
  blanks (platform legal name, privacy officer, retention, refund policy,
  liability, governing law), then sets `legalDraft = false` and the
  effective date. The restaurant's own refund and hold policy goes in too.
- Decide on analytics. To turn it on, create a web app in the Firebase
  project (or a GA4 property), then build with
  `flutter build web --dart-define=ANALYTICS_MEASUREMENT_ID=G-XXXXXXX`.
  Without it there's no analytics and no cookie banner.
- Set up the environments ([environments.md](environments.md)). The site's
  address is `ORDERING_SITE_URL` in `config/<env>.json`, and the deploy
  workflow builds and ships the site and Functions together. When you
  connect a custom domain in Hosting, update `ORDERING_SITE_URL` to match.
- Make sure each location has its street address. Today only the platform
  admin sets it, when creating the location.
- Submit `https://<site>/sitemap.xml` in Google Search Console.
