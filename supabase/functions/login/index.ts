import { createClient } from "npm:@supabase/supabase-js@2";

// Login with username (or email) + password.
// The browser never sees the email that belongs to a username. Unknown user and wrong password
// give the same answer. Rate limits of Supabase Auth apply to the password check.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  let body: { login?: string; password?: string } = {};
  try { body = await req.json(); } catch { return json({ error: "bad_request" }, 400); }
  const login = String(body.login ?? "").trim();
  const password = String(body.password ?? "");
  if (!login || !password || login.length > 120 || password.length > 72) return json({ error: "invalid_login" }, 401);

  const url = Deno.env.get("SUPABASE_URL")!;
  const service = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  let email = login.includes("@") ? login : null;
  if (!email) {
    const r = await service.rpc("login_email", { p_username: login });
    email = (r.data as string | null) ?? null;
  }
  // unknown username: run a sign-in anyway so the answer and timing look the same
  const anon = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { auth: { persistSession: false } });
  const res = await anon.auth.signInWithPassword({ email: email ?? "nobody@invalid.example", password });
  if (res.error || !res.data.session) {
    const m = String(res.error?.message ?? "").toLowerCase();
    if (m.includes("rate") || m.includes("too many")) return json({ error: "rate_limited" }, 429);
    if (m.includes("banned")) return json({ error: "disabled" }, 403);
    return json({ error: "invalid_login" }, 401);
  }
  const s = res.data.session;
  return json({ session: { access_token: s.access_token, refresh_token: s.refresh_token } });
});
