import { beforeEach, describe, expect, it } from "vitest";
import { updateOnlineOrdering } from "../src/handlers/online.js";
import {
  clip,
  handleSiteRequest,
  listedSlugs,
  loadStoreMeta,
  pageFor,
  renderShell,
  robotsTxt,
  sitemapXml,
  type StoreMeta,
} from "../src/site/seo.js";
import { caller, db, resetEmulators, seed, setOrg, u } from "./setup.js";

const SITE = "https://order.example.test/";
const TEMPLATE = `<!DOCTYPE html><html><head>
  <base href="/">
  <!--seo:start-->
  <title>Order online</title>
  <!--seo:end-->
</head><body><script src="flutter_bootstrap.js" async></script></body></html>`;

const maple: StoreMeta = {
  slug: "maple-cambridge",
  brandName: "Maple <Tea>",
  locationName: "Cambridge",
  address: "12 Main St, Cambridge, ON",
  listed: true,
  pickupLeadMinutes: 15,
};
const lookup = async (slug: string) => (slug === maple.slug ? maple : null);

describe("page meta", () => {
  it("describes a store with its own name, address and canonical link", async () => {
    const { status, meta } = await pageFor("/maple-cambridge", SITE, lookup);
    expect(status).toBe(200);
    expect(meta).toMatchObject({
      title: "Maple <Tea> · Cambridge · Order online for pickup",
      canonical: "https://order.example.test/maple-cambridge",
      image: "https://order.example.test/og-image.png",
      noindex: false,
    });
    expect(meta.description).toContain("at 12 Main St, Cambridge, ON");
    expect(meta.description.length).toBeLessThanOrEqual(160);
  });

  it("leaves the address out when the store has none", async () => {
    const { meta } = await pageFor("/maple-cambridge", SITE, async () => ({ ...maple, address: null }));
    expect(meta.description).toMatch(/^Order Maple <Tea> ahead for pickup\. Ready/);
  });

  it("keeps order pages and unlisted stores out of search", async () => {
    expect((await pageFor("/maple-cambridge/order/web_abc", SITE, lookup)).meta.noindex).toBe(true);
    expect((await pageFor("/maple-cambridge", SITE, async () => ({ ...maple, listed: false }))).meta.noindex).toBe(true);
  });

  it("answers 404 for unknown stores and paths", async () => {
    for (const path of ["/nobody-here", "/maple-cambridge/menu", "/a/b/c/d", "/Bad Slug", "/maple-cambridge/order"]) {
      expect((await pageFor(path, SITE, lookup)).status, path).toBe(404);
    }
  });

  it("has pages for the home page and the legal pages", async () => {
    expect((await pageFor("/", SITE, lookup)).status).toBe(200);
    expect((await pageFor("/privacy", SITE, lookup)).meta.title).toContain("Privacy policy");
    expect((await pageFor("/terms", SITE, lookup)).meta.title).toContain("Terms of use");
    const storePrivacy = await pageFor("/maple-cambridge/privacy", SITE, lookup);
    expect(storePrivacy).toMatchObject({ status: 200, meta: { canonical: "https://order.example.test/maple-cambridge/privacy" } });
  });

  it("clips long descriptions on a word", () => {
    const text = "word ".repeat(60);
    expect(clip(text).length).toBeLessThanOrEqual(160);
    expect(clip(text).endsWith("word…")).toBe(true);
  });
});

describe("rendering", () => {
  it("replaces the default tags and escapes store names", async () => {
    const { meta } = await pageFor("/maple-cambridge", SITE, lookup);
    const html = renderShell(TEMPLATE, meta);
    expect(html).toContain("<title>Maple &lt;Tea&gt; · Cambridge · Order online for pickup</title>");
    expect(html).toContain('<meta property="og:image" content="https://order.example.test/og-image.png">');
    expect(html).not.toContain("<title>Order online</title>");
    expect(html).not.toContain("<Tea>");
    expect(html).toContain('<script src="flutter_bootstrap.js" async></script>');
  });

  it("fails loudly when index.html lost its markers", () => {
    expect(() => renderShell("<html></html>", { title: "", description: "", canonical: "", image: "", imageAlt: "", noindex: true }))
      .toThrow(/seo:start/);
  });

  it("serves robots.txt, the sitemap and pages with sensible caching", async () => {
    const template = async () => TEMPLATE;
    const robots = await handleSiteRequest("/robots.txt", SITE, template, lookup, async () => []);
    expect(robots.body).toContain("Sitemap: https://order.example.test/sitemap.xml");
    expect(robots.body).toContain("Disallow: /*/order/");
    const map = await handleSiteRequest("/sitemap.xml", SITE, template, lookup, async () => ["maple-cambridge"]);
    expect(map.contentType).toContain("xml");
    expect(map.body).toContain("<loc>https://order.example.test/maple-cambridge</loc>");
    const page = await handleSiteRequest("/maple-cambridge?utm_source=x", SITE, template, lookup);
    expect(page).toMatchObject({ status: 200, cacheControl: expect.stringContaining("public") });
    const missing = await handleSiteRequest("/nobody-here", SITE, template, lookup);
    expect(missing).toMatchObject({ status: 404, cacheControl: "private, no-store" });
    expect(missing.body).toContain('<meta name="robots" content="noindex">');
  });

  it("builds robots.txt and the sitemap from the site's address", () => {
    expect(robotsTxt("https://a.test")).toContain("Sitemap: https://a.test/sitemap.xml");
    expect(sitemapXml("https://a.test/", [])).toContain("<loc>https://a.test/</loc>");
  });
});

describe("stores from Firestore", () => {
  const ids = { orgId: "org-a", locationId: "cambridge" };
  beforeEach(async () => {
    await resetEmulators();
    await seed();
    await db().doc("orgs/org-a/locations/cambridge").update({ address: "12 Main St" });
  });

  it("lists only stores taking online orders in the sitemap", async () => {
    await updateOnlineOrdering(caller(u.managerCam), { ...ids, enabled: true, slug: "maple-cambridge" });
    await updateOnlineOrdering(caller(u.ownerA), { orgId: "org-a", locationId: "toronto", slug: "maple-toronto" });
    expect(await listedSlugs()).toEqual(["maple-cambridge"]);
    expect(await loadStoreMeta("maple-cambridge")).toMatchObject({ address: "12 Main St", listed: true });
    expect(await loadStoreMeta("maple-toronto")).toMatchObject({ listed: false });
    expect(await loadStoreMeta("nobody-here")).toBeNull();
    // A lapsed org stops taking orders but stays listed until it's suspended.
    await setOrg("org-a", { status: "suspended" });
    expect(await listedSlugs()).toEqual([]);
  });
});
