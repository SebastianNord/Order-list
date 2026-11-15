# Order List

Shared daily order list for installers (electricians, plumbers, and others). Each
person adds what they need for tomorrow, the lead sees one merged list with who
asked for what, tags each item with a supplier and exports a CSV per supplier.

- Swedish and English, light and dark theme
- Real accounts: email, username and password. Log in with username (or email) and password. A code at sign-up decides the role: the project's **join code** makes you an electrician, the company's **lead code** makes you a lead. A company's **admin code** (separate path) makes you a second admin. Create a company to become its admin
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

### Accounts and roles

- **Log in:** username (or email) and password. The Edge Function `login` looks up the email for the username on the server, so emails are never exposed to the browser. Forgot password: email plus a 6-digit code.
- **Create account:** email, username (3 to 20 letters, digits, `.` `-` `_`, unique), password (at least 8 characters) and a code. The email is confirmed with a 6-digit code. One account belongs to one company and can be in several of its projects. Add more projects later with their join codes (picker screen).
- **Electrician:** signs up with the project's join code (8 characters; older 6-character codes work until rotated). Adds items, changes or removes their own items until the lead has ordered them.
- **Lead:** signs up with the company's **lead code**. Sees every project of the company, opens or creates projects and is lead in the ones they open. Reads and changes the join code under the Team tab. Can change or delete any item, add article numbers, mark items ordered, set the cut-off time, export CSV and manage the company's suppliers.
- **Company admin:** creates the company (**Create company**: org number and name, valid checksum, one org number once) or signs up with a company's **admin code** (I have a company admin code: org number + code). The system makes the admin code and the lead code and shows them once when the company is created. Admins start projects, read and change the lead code and make a new admin code (the old one stops working). The admin code is stored hashed.
- **App owner:** you, in `/admin.html` (magic link). Suppliers, catalog, companies and **Users**: list per company (username, email, role, projects), change company role (admin, lead, member), set project role or remove from a project, remove from company, send a password reset email, disable or enable, delete. Delete removes the account; items stay in the project as history. The owner account is never touched here. A disabled user is signed out; an open page can keep working until its token expires (up to 1 hour).
- **Companies** are approved immediately. The pending and rejected states still exist for the owner (Companies tab) if a company has to be blocked.
- **Wrong codes:** 10 wrong codes per account per 15 minutes, and 300 in total (also for people without an account). After that codes are refused until the window passes.

Not secret on purpose: the company list and status are readable by signed-in users. Codes live in tables the app cannot read directly (`company_access`, `project_secrets`, `company_admins`, `company_leads`, `profiles`); only the database functions use them.

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
  `items_supplier_lead_only`, then the files in `supabase/migrations/` from `20261109221000_add_admin_area` on, including `20261115010000_company_admin_and_join_codes`, `20261115120000_join_with_code` and `20261115140000_company_lead_code_login`, `20261115170000_team_member_list`, `20261115190000_my_access` and `20261116100000_accounts_username_login` (accounts; **clean cut**: old anonymous members and roles are removed, items stay).
  Apply a new migration **before** deploying the page that needs it.
- Rollback tests live in `supabase/tests/`. Run one in the SQL editor after its migration; it rolls itself back.
- Preset suppliers are rows in `suppliers` with `company_id` null. Only the app
  owner changes them (SQL or dashboard); the app has no write access to them.

## Supabase settings (steps in the dashboard, project `order-list`)

Needed for sign-up and password reset by email:

1. **Authentication, Sign In / Providers:** Email provider on, **Confirm email** on. Anonymous sign-ins can be switched **off** (the app no longer uses them). Minimum password length 8.
2. **Authentication, Email Templates:** the app asks for a 6-digit code, so these templates must contain `{{ .Token }}`:
   - **Confirm signup**, for example `<h2>Your confirmation code</h2><p>{{ .Token }}</p>`
   - **Reset Password**, for example `<h2>Your reset code</h2><p>{{ .Token }}</p>`
   - **Magic Link** (the owner signs in to `/admin.html` with a link, this one keeps its link).
3. **Authentication, SMTP Settings:** your own SMTP (for example Resend or Brevo, free tiers) with a sender on your own domain. The built-in sender only allows a few emails per hour and, as far as I know, only delivers to people in your Supabase team.
4. **Authentication, Rate Limits:** after step 3, check the emails-per-hour limit. **Providers, Email:** OTP expiry 3600 seconds or less.
5. **Edge Function `login`** (source in `supabase/functions/login/`): deploy it with JWT verification on (`supabase functions deploy login`, or the dashboard). It uses the built-in `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY`; nothing to configure.

Without step 2 or 3 sign-up cannot send its code. Without step 5 the login screen shows a server error.

## Not built yet

- Company article list (CSV upload by leads, one shared list per company)
- Matching items against a supplier catalog (the search link opens for now)
- Bolagsverket lookup when adding a company
- Reminders before the cut-off
- Sending orders straight to a supplier
