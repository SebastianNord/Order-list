-- add_suppliers
-- Suppliers: one table. company_id is null = preset shared by all companies
-- (maintained by the app owner with SQL, no write policy). company_id set =
-- private to that company, managed by any lead in that company.
-- Projects get a default supplier, items can be tagged with a supplier.

create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  company_id text references public.companies(org_nr),
  name text not null check (char_length(btrim(name)) between 2 and 40),
  search_url text not null check (
    search_url ~ '^https://'
    and position('{q}' in search_url) > 0
    and char_length(search_url) <= 300
  ),
  sort integer not null default 100,
  created_at timestamptz not null default now()
);

create unique index suppliers_name_uniq
  on public.suppliers (coalesce(company_id, ''), lower(btrim(name)));
create index suppliers_company_idx on public.suppliers (company_id);

alter table public.suppliers enable row level security;
revoke all on public.suppliers from anon;

-- Company level checks (a lead of any project in the company counts as a lead).
create function public.is_company_member(cid text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.members m
    where m.company_id = cid and m.user_id = (select auth.uid()));
$$;

create function public.is_company_lead(cid text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.members m
    where m.company_id = cid and m.user_id = (select auth.uid()) and m.role = 'lead');
$$;

revoke all on function public.is_company_member(text) from public, anon;
revoke all on function public.is_company_lead(text) from public, anon;
grant execute on function public.is_company_member(text) to authenticated;
grant execute on function public.is_company_lead(text) to authenticated;

create policy suppliers_select on public.suppliers for select to authenticated
  using (company_id is null or public.is_company_member(company_id));

create policy suppliers_insert on public.suppliers for insert to authenticated
  with check (company_id is not null and public.is_company_lead(company_id));

create policy suppliers_update on public.suppliers for update to authenticated
  using (company_id is not null and public.is_company_lead(company_id))
  with check (company_id is not null and public.is_company_lead(company_id));

create policy suppliers_delete on public.suppliers for delete to authenticated
  using (company_id is not null and public.is_company_lead(company_id));

-- Default supplier per project (lead sets it through the existing projects update rule).
alter table public.projects
  add column default_supplier_id uuid references public.suppliers(id) on delete set null;
create index projects_default_supplier_idx on public.projects (default_supplier_id)
  where default_supplier_id is not null;

-- Supplier tag on items.
alter table public.items
  add column supplier_id uuid references public.suppliers(id) on delete set null;
create index items_supplier_idx on public.items (supplier_id)
  where supplier_id is not null;

-- A supplier on a project or item must be a preset or belong to the same company.
create function public.check_supplier_company()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  sid uuid;
  ok boolean;
begin
  if tg_table_name = 'projects' then
    sid := new.default_supplier_id;
  else
    sid := new.supplier_id;
  end if;
  if sid is not null then
    select exists (select 1 from public.suppliers s
      where s.id = sid and (s.company_id is null or s.company_id = new.company_id)) into ok;
    if not ok then
      raise exception 'supplier not available for this company' using errcode = '23514';
    end if;
  end if;
  return new;
end $$;

revoke all on function public.check_supplier_company() from public, anon, authenticated;

create trigger projects_check_supplier
  before insert or update of default_supplier_id on public.projects
  for each row execute function public.check_supplier_company();

create trigger items_check_supplier
  before insert or update of supplier_id on public.items
  for each row execute function public.check_supplier_company();

-- Starter presets. The link is a web search limited to the supplier's site;
-- {q} is replaced by the article number or search word.
insert into public.suppliers (company_id, name, search_url, sort) values
  (null, 'Rexel',          'https://www.google.com/search?q=site:rexel.se+{q}',          10),
  (null, 'Ahlsell',        'https://www.google.com/search?q=site:ahlsell.se+{q}',        20),
  (null, 'Dahl',           'https://www.google.com/search?q=site:dahl.se+{q}',           30),
  (null, 'Elektroskandia', 'https://www.google.com/search?q=site:elektroskandia.se+{q}', 40),
  (null, 'Onninen',        'https://www.google.com/search?q=site:onninen.se+{q}',        50);
