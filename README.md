# Order List

Shared daily order list for electricians. Each person adds what they need for
tomorrow, the lead sees one merged list with who asked for what, and exports it
as CSV for Rexel.

- Swedish and English, light and dark theme
- Join with project ID and name. The lead also uses a lead code
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
  numbers, mark items ordered, set the cut-off time and export CSV.

## Deploy on Cloudflare Pages

1. Cloudflare dashboard, Workers & Pages, Create, Pages, Connect to Git.
2. Pick this repository and the `main` branch.
3. Framework preset: **None**. Build command: leave empty. Build output
   directory: `/`.
4. Save and deploy. Every push to `main` deploys automatically.

## Supabase setup (already done)

- Authentication, Sign In / Providers: **Allow anonymous sign-ins** is on.
- Tables: `projects`, `members`, `items`, `favorites`, plus the `join_project`
  function. The schema was applied as the migration `initial_order_list_schema`.

## Not built yet

- Matching items against the Rexel catalog (the button opens a search for now)
- Reminders before the cut-off
- Sending orders straight to Rexel
