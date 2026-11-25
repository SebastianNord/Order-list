import { createClient } from "npm:@supabase/supabase-js@2";

// Article lookup against a supplier site: E-number in, product title out.
// Body: { supplier: "rexel", number: "1402081" }. Signed-in users only.
// 6 digits are tried as typed and then with a leading 0 (Rexel lists some numbers like 06 610 86).
// Answers: { found: true, article, name, image } | { found: false } | { found: false, error: "unavailable" }.
// Results are cached in supplier_product_cache (found 30 days, not found 1 day). A failed fetch is not cached.
// To add a supplier: add an entry to ADAPTERS. The host is fixed per adapter and only digits are inserted
// into the URL, so the function cannot be used to fetch other sites.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const FOUND_DAYS = 30;
const NOT_FOUND_DAYS = 1;

type Adapter = {
  /** the lookup page for one article number */
  url: (n: string) => string;
  /** true when the final address is that product's page */
  isProduct: (finalUrl: string, html: string, n: string) => boolean;
  image: (n: string) => string;
};

const ADAPTERS: Record<string, Adapter> = {
  rexel: {
    // The site search sends an exact E-number straight to the product page (.../p/<number>).
    url: (n) => `https://www.rexel.se/swe/search/?text=${n}`,
    isProduct: (finalUrl, html, n) => {
      const re = new RegExp(`/p/${n}(?:[/?#"]|$)`);
      if (re.test(finalUrl)) return true;
      const canon = html.match(/<link[^>]+rel=["']canonical["'][^>]*>/i)?.[0] ?? "";
      return re.test(canon);
    },
    image: (n) => `https://apim-rxlse-prod-int-01.azure-api.net/pimv2/article/media/${n}/MEDIUM`,
  },
};

function decode(s: string): string {
  return s
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(+d))
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&nbsp;/g, " ").replace(/&quot;/g, '"').replace(/&apos;/g, "'")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
}
const clean = (s: string) => decode(s.replace(/<[^>]*>/g, " ")).replace(/\s+/g, " ").trim();

/** product title: the first h1, else the page title without "Köp " and the trailing " | ..." parts */
function parseName(html: string): string | null {
  const h1 = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i);
  let name = h1 ? clean(h1[1]) : "";
  if (!name) {
    const t = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
    if (t) name = clean(t[1]).split("|")[0].replace(/^Köp\s+/i, "").trim();
  }
  return name ? name.slice(0, 120) : null;
}

/** null = not a product page; throws when the supplier site cannot be reached */
async function fetchName(a: Adapter, n: string): Promise<string | null> {
  const res = await fetch(a.url(n), {
    redirect: "follow",
    headers: {
      "User-Agent": "Mozilla/5.0 (compatible; OrderListBot/1.0; +https://github.com/SebastianNord/order-list)",
      "Accept": "text/html",
      "Accept-Language": "sv-SE,sv;q=0.9,en;q=0.5",
    },
    signal: AbortSignal.timeout(7000),
  });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`supplier_status_${res.status}`);
  const html = (await res.text()).slice(0, 1_500_000);
  if (!a.isProduct(res.url, html, n)) return null;
  return parseName(html);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const authed = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    auth: { persistSession: false },
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const who = await authed.auth.getUser();
  if (who.error || !who.data.user) return json({ error: "unauthorized" }, 401);

  let body: { supplier?: string; number?: string } = {};
  try { body = await req.json(); } catch { return json({ error: "bad_request" }, 400); }
  const supplier = String(body.supplier ?? "");
  const adapter = Object.hasOwn(ADAPTERS, supplier) ? ADAPTERS[supplier] : undefined;
  if (!adapter) return json({ error: "unknown_supplier" }, 400);
  const typed = String(body.number ?? "").replace(/\s+/g, "");
  if (!/^\d{6,7}$/.test(typed)) return json({ error: "bad_number" }, 400);
  const candidates = typed.length === 6 ? [typed, "0" + typed] : [typed];

  const db = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const cached = await db.from("supplier_product_cache")
    .select("article_no,found,name,fetched_at").eq("supplier_key", supplier).in("article_no", candidates);
  const fresh = new Map<string, { found: boolean; name: string | null }>();
  for (const r of cached.data ?? []) {
    const ageDays = (Date.now() - new Date(r.fetched_at).getTime()) / 86_400_000;
    if (ageDays < (r.found ? FOUND_DAYS : NOT_FOUND_DAYS)) fresh.set(r.article_no, r);
  }

  let failed = false;
  for (const n of candidates) {
    let hit = fresh.get(n);
    if (!hit) {
      try {
        const name = await fetchName(adapter, n);
        hit = { found: name !== null, name };
        await db.from("supplier_product_cache").upsert({
          supplier_key: supplier, article_no: n, found: hit.found, name: hit.name, fetched_at: new Date().toISOString(),
        });
      } catch {
        failed = true;
        continue;
      }
    }
    if (hit.found && hit.name) return json({ found: true, article: n, name: hit.name, image: adapter.image(n) });
  }
  return json(failed ? { found: false, error: "unavailable" } : { found: false });
});
