# Order List

Shared daily order list for installers (electricians, plumbers, and others). Each
person adds what they need for tomorrow, the lead sees one merged list with who
asked for what, tags each item with a supplier and exports a CSV per supplier.

- Swedish and English, light and dark theme
- Join with company, project ID and name. The lead also uses a lead code
- Suppliers: a preset list shared by all companies, plus a company's own
  suppliers. A supplier is a name and a search link (`{q}` is replaced by the
  article number or search word). The lead picks a default supplier per project
  and can tag single items with another one. No automatic matching: the lead
  confirms each match through the search link
- Live sync between phones, cut-off time, favorites
- History: flat list of every item ever added in the project (no names, no status) with a quantity picker to add it to today's order
- Static site (`index.html`), no build step

## How it fits together

| Part | Role |
| --- | --- |
| GitHub | This repository |
| Cloudflare Pages | Hosts the static files |
| Supabase (`order-list`, eu-north-1) | Database, anonymous sign-in, live updates |

The browser talks to Supabase directly. Access rules live in the database
(row level security), so the public anon key in `config.js` is safe to publish.

### Roles

- **Electrician:** joins with project ID and name. Adds items, changes or
  removes their own items until the lead has ordered them.
- **Lead:** the first person to join a new project ID as lead chooses its lead
  code. Later leads need that code. Can change or delete any item, add article
  numbers, mark items ordered, set the cut-off time and export CSV. Chooses the
  project's default supplier (required before ordering), tags items with a
  supplier, and adds, changes or deletes the company's own suppliers (any lead
  in the company can). Only leads can set an item's supplier; this is enforced
  in the database.

## Deploy on Cloudflare Pages

1. Cloudflare dashboard, Workers & Pages, Create, Pages, Connect to Git.
2. Pick this repository and the `main` branch.
3. Framework preset: **None**. Build command: leave empty. Build output
   directory: `/`.
4. Save and deploy. Every push to `main` deploys automatically.

## Supabase setup (already done)

- Authentication, Sign In / Providers: **Allow anonymous sign-ins** is on.
- Tables: `companies`, `projects`, `members`, `items`, `favorites`, `suppliers`,
  plus the `join_project` and `add_company` functions. Schema changes live in
  `supabase/migrations/` and are applied in order: `initial_order_list_schema`,
  `add_company_layer`, `add_suppliers`, `suppliers_grants`,
  `items_supplier_lead_only`.
- Preset suppliers are rows in `suppliers` with `company_id` null. Only the app
  owner changes them (SQL or dashboard); the app has no write access to them.

## Not built yet

- Company article list (CSV upload by leads, one shared list per company)
- Matching items against a supplier catalog (the search link opens for now)
- Bolagsverket lookup when adding a company
- Reminders before the cut-off
- Sending orders straight to a supplier
