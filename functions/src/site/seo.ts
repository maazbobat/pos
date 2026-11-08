/**
 * Server side of the ordering site: the parts search engines and link
 * previews need, which a Flutter web app can't give them on its own.
 *
 * Firebase Hosting serves the built site (apps/online/build/web) and sends
 * every path that isn't a file here (firebase.json). This answers:
 *   /robots.txt        what crawlers may read, and where the sitemap is
 *   /sitemap.xml       the home page and every store taking online orders
 *   anything else      the site's index.html with this page's title,
 *                      description, canonical link and Open Graph tags, and
 *                      a real 404 status for unknown stores and paths
 *
 * Routes here must match apps/online/lib/src/app.dart.
 */
import { db } from "../lib/firebase.js";
import { loadStore, RESERVED_SLUGS, validSlug } from "../handlers/online.js";

export interface StoreMeta {
  slug: string;
  brandName: string;
  locationName: string;
  address: string | null;
  listed: boolean;
  pickupLeadMinutes: number;
}

export interface PageMeta {
  title: string;
  description: string;
  /** Absolute URL of this page. */
  canonical: string;
  image: string;
  imageAlt: string;
  noindex: boolean;
}

export interface SiteResponse {
  status: number;
  contentType: string;
  cacheControl: string;
  body: string;
}

const SITE_NAME = "Order online";
const DEFAULT_DESCRIPTION = "Order ahead from your favourite local restaurant and skip the line. Pay online or at pickup.";
/** Markers around the tags this replaces in apps/online/web/index.html. */
const START = "<!--seo:start-->";
const END = "<!--seo:end-->";

export function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

function trimSlash(url: string): string {
  return url.replace(/\/+$/, "");
}

export function storeDisplayName(s: Pick<StoreMeta, "brandName" | "locationName">): string {
  return [s.brandName, s.locationName].filter((v) => v.trim().length > 0).join(" · ") || "Restaurant";
}

/** A description of at most 160 characters, cut on a word. */
export function clip(text: string, max = 160): string {
  if (text.length <= max) return text;
  const cut = text.slice(0, max - 1);
  return `${cut.slice(0, Math.max(cut.lastIndexOf(" "), max - 20)).trimEnd()}…`;
}

/** Which page a path is, and its meta tags. `store` is only called for store paths. */
export async function pageFor(
  path: string,
  siteUrl: string,
  store: (slug: string) => Promise<StoreMeta | null>,
): Promise<{ status: number; meta: PageMeta }> {
  const base = trimSlash(siteUrl);
  const parts = path.split("?")[0].split("/").filter((p) => p.length > 0).map((p) => p.toLowerCase());
  const image = `${base}/og-image.png`;
  const imageAlt = "Order ahead for pickup";
  const page = (status: number, m: Omit<PageMeta, "image" | "imageAlt"> & Partial<PageMeta>) =>
    ({ status, meta: { image, imageAlt, ...m } });
  const notFound = () => page(404, {
    title: `Page not found · ${SITE_NAME}`,
    description: "We couldn't find that page. Check the link from the restaurant.",
    canonical: `${base}/`,
    noindex: true,
  });

  if (parts.length === 0) {
    return page(200, { title: `${SITE_NAME} for pickup`, description: DEFAULT_DESCRIPTION, canonical: `${base}/`, noindex: false });
  }
  if (parts.length === 1 && (parts[0] === "privacy" || parts[0] === "terms")) {
    const privacy = parts[0] === "privacy";
    return page(200, {
      title: `${privacy ? "Privacy policy" : "Terms of use"} · ${SITE_NAME}`,
      description: privacy
        ? "How restaurants on this ordering site collect, use and protect your personal information."
        : "The terms that apply when you order ahead on this site.",
      canonical: `${base}/${parts[0]}`,
      noindex: false,
    });
  }
  const slug = parts[0];
  if (!validSlug(slug) || RESERVED_SLUGS.has(slug) || parts.length > 3) return notFound();
  const isOrder = parts.length === 3 && parts[1] === "order";
  const isLegal = parts.length === 2 && (parts[1] === "privacy" || parts[1] === "terms");
  if (parts.length > 1 && !isOrder && !isLegal) return notFound();

  const s = await store(slug);
  if (!s) return notFound();
  const name = storeDisplayName(s);
  const canonical = `${base}/${slug}`;
  if (isOrder) {
    // Private to whoever holds the link: never indexed, never described.
    return page(200, { title: `Your order · ${name}`, description: `Your pickup order from ${name}.`, canonical, noindex: true });
  }
  if (isLegal) {
    const privacy = parts[1] === "privacy";
    return page(200, {
      title: `${privacy ? "Privacy policy" : "Terms of use"} · ${name}`,
      description: `${privacy ? "How" : "The terms under which"} ${name} ${privacy ? "handles your personal information when you order online." : "takes online orders."}`,
      canonical: `${canonical}/${parts[1]}`,
      noindex: true,
    });
  }
  const where = s.address ? ` at ${s.address}` : "";
  return page(200, {
    title: `${name} · Order online for pickup`,
    description: clip(`Order ${s.brandName || name} ahead for pickup${where}. Ready in about ${s.pickupLeadMinutes} minutes. See the menu and prices, and pay online or at pickup.`),
    canonical,
    imageAlt: `${name}: order ahead for pickup`,
    // A store that turned online ordering off still answers, but stays out of search.
    noindex: !s.listed,
  });
}

/** The head tags for [meta], as they go between the markers. */
export function metaTags(meta: PageMeta): string {
  const e = escapeHtml;
  return [
    `<title>${e(meta.title)}</title>`,
    `<meta name="description" content="${e(meta.description)}">`,
    `<link rel="canonical" href="${e(meta.canonical)}">`,
    meta.noindex ? `<meta name="robots" content="noindex">` : `<meta name="robots" content="index, follow">`,
    `<meta property="og:type" content="website">`,
    `<meta property="og:site_name" content="${SITE_NAME}">`,
    `<meta property="og:title" content="${e(meta.title)}">`,
    `<meta property="og:description" content="${e(meta.description)}">`,
    `<meta property="og:url" content="${e(meta.canonical)}">`,
    `<meta property="og:image" content="${e(meta.image)}">`,
    `<meta property="og:image:width" content="1200">`,
    `<meta property="og:image:height" content="630">`,
    `<meta property="og:image:alt" content="${e(meta.imageAlt)}">`,
    `<meta property="og:locale" content="en_CA">`,
    `<meta name="twitter:card" content="summary_large_image">`,
  ].join("\n  ");
}

/** Puts [meta] into the site's index.html, replacing the default tags between the markers. */
export function renderShell(template: string, meta: PageMeta): string {
  const start = template.indexOf(START);
  const end = template.indexOf(END);
  if (start < 0 || end < start) throw new Error("index.html has no <!--seo:start--> … <!--seo:end--> block");
  return `${template.slice(0, start + START.length)}\n  ${metaTags(meta)}\n  ${template.slice(end)}`;
}

export function robotsTxt(siteUrl: string): string {
  return [
    "User-agent: *",
    "Allow: /",
    // Order pages are private to the guest who holds the link.
    "Disallow: /*/order/",
    "",
    `Sitemap: ${trimSlash(siteUrl)}/sitemap.xml`,
    "",
  ].join("\n");
}

export function sitemapXml(siteUrl: string, slugs: string[]): string {
  const base = trimSlash(siteUrl);
  const urls = [`${base}/`, ...slugs.map((s) => `${base}/${s}`), `${base}/privacy`, `${base}/terms`];
  return [
    `<?xml version="1.0" encoding="UTF-8"?>`,
    `<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">`,
    ...urls.map((u) => `  <url><loc>${escapeHtml(u)}</loc></url>`),
    `</urlset>`,
    "",
  ].join("\n");
}

/** A store's meta from Firestore, or null when there's no such store. */
export async function loadStoreMeta(slug: string): Promise<StoreMeta | null> {
  try {
    const s = await loadStore(slug);
    return {
      slug,
      brandName: s.brandName,
      locationName: s.locationName,
      address: s.address,
      listed: s.listed,
      pickupLeadMinutes: s.settings.pickupLeadMinutes,
    };
  } catch {
    return null;
  }
}

/** Every store taking online orders, for the sitemap. */
export async function listedSlugs(limit = 5000): Promise<string[]> {
  const links = await db().collection("storefronts").limit(limit).get();
  const metas = await Promise.all(links.docs.map((d) => loadStoreMeta(d.id)));
  return metas.filter((m): m is StoreMeta => m !== null && m.listed).map((m) => m.slug).sort();
}

/**
 * Answers one request that Hosting passed on. [template] gives the built
 * index.html (Hosting serves it as a file, so the caller fetches and caches it).
 */
export async function handleSiteRequest(
  path: string,
  siteUrl: string,
  template: () => Promise<string>,
  store: (slug: string) => Promise<StoreMeta | null> = loadStoreMeta,
  slugs: () => Promise<string[]> = () => listedSlugs(),
): Promise<SiteResponse> {
  const clean = path.split("?")[0];
  if (clean === "/robots.txt") {
    return { status: 200, contentType: "text/plain; charset=utf-8", cacheControl: "public, max-age=3600", body: robotsTxt(siteUrl) };
  }
  if (clean === "/sitemap.xml") {
    return { status: 200, contentType: "application/xml; charset=utf-8", cacheControl: "public, max-age=3600", body: sitemapXml(siteUrl, await slugs()) };
  }
  const { status, meta } = await pageFor(clean, siteUrl, store);
  return {
    status,
    contentType: "text/html; charset=utf-8",
    // Short, so a menu or address change shows up in previews soon.
    cacheControl: status === 200 && !meta.noindex ? "public, max-age=300, s-maxage=600" : "private, no-store",
    body: renderShell(await template(), meta),
  };
}
