# Order List

Shared daily order list for installers (electricians, plumbers, and others). Each
person adds what they need for tomorrow, the lead sees one merged list with who
asked for what, tags each item with a supplier and exports a CSV per supplier.

- Swedish and English, light and dark theme
- One code box for everyone: name + code. A project's **join code** makes you a member, the company's **lead code** makes you a lead. Company admins use their own screen (company + admin code)
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

- **App owner:** you, in `/admin.html`. Approves new companies, hands out company admin codes, manages preset suppliers and the catalog.
- **Company admin:** the person who adds a new company (and chooses its admin code), or anyone who enters the admin code on a new phone. Starts projects and gives out the company's lead invite code.

- **Electrician:** joins with name and the project's join code (8 characters; older 6-character codes work until rotated). Join codes are unique across all companies. On a new phone the code is entered again. Adds items, changes or removes their own items until the lead has ordered them.
- **Lead:** signs in with name and the company's **lead code** (the company admin hands it out; the app owner can read it in `/admin.html`, Companies tab, for companies without an admin). A lead sees every project of the company, opens one or creates a new one, and is lead in the projects they open. Reads and changes the join code under the Team tab. Can change or delete any item, add article numbers, mark items ordered, set the cut-off time and export CSV. Chooses the project's default supplier (required before ordering), tags items with a supplier, and adds, changes or deletes the company's own suppliers. Only leads can set an item's supplier; this is enforced in the database.
- **Wrong codes:** each phone gets 10 wrong codes per 15 minutes, and all phones together 300. After that sign-in with a code is blocked until the window passes.

### Email sign-in for company admins (optional)

An admin can save their sign-in with an email, so a new or cleared phone does not lock them out. On the admin screen the admin box shows a reminder until an email is saved: enter the email, then the 6-digit code that arrives. This links the email to the same user, so admin rights and projects stay. On a new phone: admin screen, "Sign in with my email (new phone)", email, then the code. The admin code still works as a fallback. Leads keep using the lead code; there is no email sign-in for them or for `/admin.html`.

One-time setup in the Supabase dashboard (Authentication, Emails, Templates). Add the code to the **Magic link** and **Change email address** templates, for example `<p>Your code: {{ .Token }}</p>`. The built-in email service sends only a few emails per hour and is best-effort: fine for a pilot, but set up custom SMTP (Authentication, Emails, SMTP settings) before many admins use it.

### Joining and approval

1. Someone adds a company with a valid org number and chooses an admin code. The company is **pending**: nobody can join projects in it yet.
2. The app owner approves it in `/admin.html`, Companies tab (Pending shows first). Existing companies are already approved.
3. The company admin gives the company **lead code** (shown on the admin screen) to the leads.
4. A lead signs in with the lead code, then creates projects (the lead chooses the project ID) or opens existing ones. Only company admins and leads can create projects.
5. A lead shares the project's join code or link (Team tab). Electricians enter it once per phone. Changing the code does not remove people already in.
6. Forgotten admin code: the owner creates a new one in `/admin.html`. Codes are shown once (admin code) or can be read again by the right people (lead code, join code). The admin code is not stored in clear text.

Not secret on purpose: the company list and each company's status are readable by everyone. Codes live in tables the app cannot read directly (`company_access`, `project_secrets`, `company_admins`, `company_leads`); only the database functions use them.

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
  `items_supplier_lead_only`, then the files in `supabase/migrations/` from `20261109221000_add_admin_area` on, including `20261115010000_company_admin_and_join_codes`, `20261115120000_join_with_code` and `20261115140000_company_lead_code_login`.
  Apply a new migration **before** deploying the page that needs it.
- Rollback tests live in `supabase/tests/`. Run one in the SQL editor after its migration; it rolls itself back.
- Preset suppliers are rows in `suppliers` with `company_id` null. Only the app
  owner changes them (SQL or dashboard); the app has no write access to them.

## Not built yet

- Company article list (CSV upload by leads, one shared list per company)
- Matching items against a supplier catalog (the search link opens for now)
- Bolagsverket lookup when adding a company
- Reminders before the cut-off
- Sending orders straight to a supplier
