-- add_admin_area
-- Owner-only admin area (/admin): admins table, preset supplier management,
-- global supplier catalog with CSV import, company tools and an audit log.
-- The admin is linked by hand after the first magic-link login (no email in the repo):
--   insert into public.admins (user_id) select id from auth.users where email = '<admin email>';

-- Admins: filled by hand, no app access.
create table public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;
revoke all on public.admins from anon, authenticated;

create function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.admins a where a.user_id = (select auth.uid()));
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- Hide instead of delete: old orders keep the supplier. The app hides these in pickers.
alter table public.suppliers add column is_hidden boolean not null default false;

create policy suppliers_admin_select on public.suppliers for select to authenticated
  using (public.is_admin());
create policy suppliers_admin_insert on public.suppliers for insert to authenticated
  with check (company_id is null and public.is_admin());
create policy suppliers_admin_update on public.suppliers for update to authenticated
  using (company_id is null and public.is_admin())
  with check (company_id is null and public.is_admin());
-- No admin delete policy on purpose: presets can only be hidden.

-- Global catalog per preset supplier.
create table public.supplier_catalog (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid not null references public.suppliers(id) on delete cascade,
  article_no text not null check (char_length(btrim(article_no)) between 1 and 40),
  name text not null check (char_length(btrim(name)) between 1 and 200),
  product_url text check (product_url is null
    or (product_url ~ '^https://' and char_length(product_url) <= 500)),
  updated_at timestamptz not null default now(),
  unique (supplier_id, article_no)
);
alter table public.supplier_catalog enable row level security;
revoke all on public.supplier_catalog from anon, authenticated;
grant select, insert, update, delete on public.supplier_catalog to authenticated;

create policy catalog_select on public.supplier_catalog for select to authenticated
  using (true);
create policy catalog_admin_write on public.supplier_catalog for all to authenticated
  using (public.is_admin())
  with check (public.is_admin() and exists (
    select 1 from public.suppliers s where s.id = supplier_id and s.company_id is null));

-- Audit log: read by admin only, written by functions and triggers only.
create table public.admin_audit (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  admin_id uuid,
  action text not null,
  target text,
  details jsonb
);
alter table public.admin_audit enable row level security;
revoke all on public.admin_audit from anon, authenticated;
grant select on public.admin_audit to authenticated;
create policy audit_admin_select on public.admin_audit for select to authenticated
  using (public.is_admin());

create function public.audit_supplier_change() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if public.is_admin() then
    insert into public.admin_audit (admin_id, action, target, details)
    values ((select auth.uid()), 'supplier_' || lower(tg_op), new.id::text, to_jsonb(new));
  end if;
  return new;
end $$;
revoke all on function public.audit_supplier_change() from public, anon, authenticated;
create trigger suppliers_audit after insert or update on public.suppliers
  for each row execute function public.audit_supplier_change();

-- CSV import: dry run first (preview), then confirm. Max 5000 rows per call.
-- Last row wins for a repeated article number. Bad rows are skipped and counted.
create function public.admin_import_catalog(p_supplier uuid, p_rows jsonb, p_dry_run boolean default true)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare total int; valid int; upd_n int; new_n int;
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  if not exists (select 1 from public.suppliers where id = p_supplier and company_id is null) then
    raise exception 'supplier must be a preset' using errcode = '23514';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'rows must be an array' using errcode = '23514';
  end if;
  total := jsonb_array_length(p_rows);
  if total > 5000 then raise exception 'max 5000 rows per import' using errcode = '23514'; end if;

  with src as (
    select distinct on (btrim(r.article_no)) btrim(r.article_no) as article_no,
           btrim(r.name) as name, nullif(btrim(r.product_url), '') as product_url
      from jsonb_array_elements(p_rows) with ordinality as e(j, n),
           lateral jsonb_to_record(e.j) as r(article_no text, name text, product_url text)
     where char_length(btrim(coalesce(r.article_no, ''))) between 1 and 40
       and char_length(btrim(coalesce(r.name, ''))) between 1 and 200
       and (nullif(btrim(r.product_url), '') is null
            or (btrim(r.product_url) ~ '^https://' and char_length(btrim(r.product_url)) <= 500))
     order by btrim(r.article_no), e.n desc)
  select count(*),
         count(*) filter (where exists (select 1 from public.supplier_catalog c
                          where c.supplier_id = p_supplier and c.article_no = src.article_no))
    into valid, upd_n from src;
  new_n := valid - upd_n;

  if not p_dry_run then
    with src as (
      select distinct on (btrim(r.article_no)) btrim(r.article_no) as article_no,
             btrim(r.name) as name, nullif(btrim(r.product_url), '') as product_url
        from jsonb_array_elements(p_rows) with ordinality as e(j, n),
             lateral jsonb_to_record(e.j) as r(article_no text, name text, product_url text)
       where char_length(btrim(coalesce(r.article_no, ''))) between 1 and 40
         and char_length(btrim(coalesce(r.name, ''))) between 1 and 200
         and (nullif(btrim(r.product_url), '') is null
              or (btrim(r.product_url) ~ '^https://' and char_length(btrim(r.product_url)) <= 500))
       order by btrim(r.article_no), e.n desc)
    insert into public.supplier_catalog (supplier_id, article_no, name, product_url)
    select p_supplier, article_no, name, product_url from src
    on conflict (supplier_id, article_no)
    do update set name = excluded.name, product_url = excluded.product_url, updated_at = now();

    insert into public.admin_audit (admin_id, action, target, details)
    values ((select auth.uid()), 'catalog_import', p_supplier::text,
      jsonb_build_object('rows', total, 'new', new_n, 'updated', upd_n, 'skipped', total - valid));
  end if;
  return jsonb_build_object('rows', total, 'new', new_n, 'updated', upd_n,
    'skipped', total - valid, 'dry_run', p_dry_run);
end $$;

-- Promote a company's private supplier to a preset (in place, nothing to re-point).
create function public.admin_promote_supplier(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare old_company text;
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  select company_id into old_company from public.suppliers where id = p_id and company_id is not null;
  if old_company is null then raise exception 'not a private supplier' using errcode = '23514'; end if;
  if exists (select 1 from public.suppliers s, public.suppliers x
             where x.id = p_id and s.company_id is null
               and lower(btrim(s.name)) = lower(btrim(x.name))) then
    raise exception 'a preset with this name already exists' using errcode = '23505';
  end if;
  insert into public.admin_audit (admin_id, action, target, details)
  values ((select auth.uid()), 'supplier_promote', p_id::text, jsonb_build_object('from_company', old_company));
  update public.suppliers set company_id = null where id = p_id;
end $$;

-- Merge company p_from into p_into. Dry run first. Aborts and lists conflicts
-- (same project ID or same supplier name in both companies).
create function public.admin_merge_companies(p_from text, p_into text, p_dry_run boolean default true)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare cp text[]; cs text[]; n_proj int; n_mem int; n_items int; n_sup int;
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_from = p_into then raise exception 'same company' using errcode = '23514'; end if;
  if not exists (select 1 from public.companies where org_nr = p_from)
     or not exists (select 1 from public.companies where org_nr = p_into) then
    raise exception 'company not found' using errcode = '23503';
  end if;

  select array_agg(a.id order by a.id) into cp
    from public.projects a join public.projects b on b.company_id = p_into and b.id = a.id
   where a.company_id = p_from;
  select array_agg(a.name order by a.name) into cs
    from public.suppliers a join public.suppliers b
      on b.company_id = p_into and lower(btrim(b.name)) = lower(btrim(a.name))
   where a.company_id = p_from;
  if cp is not null or cs is not null then
    return jsonb_build_object('ok', false,
      'project_conflicts', coalesce(to_jsonb(cp), '[]'::jsonb),
      'supplier_conflicts', coalesce(to_jsonb(cs), '[]'::jsonb));
  end if;

  select count(*) into n_proj  from public.projects  where company_id = p_from;
  select count(*) into n_mem   from public.members   where company_id = p_from;
  select count(*) into n_items from public.items     where company_id = p_from;
  select count(*) into n_sup   from public.suppliers where company_id = p_from;

  if not p_dry_run then
    update public.suppliers set company_id = p_into where company_id = p_from;
    insert into public.projects (company_id, id, lead_code_hash, cutoff, created_at, default_supplier_id)
      select p_into, id, lead_code_hash, cutoff, created_at, default_supplier_id
        from public.projects where company_id = p_from;
    update public.members   set company_id = p_into where company_id = p_from;
    update public.items     set company_id = p_into where company_id = p_from;
    update public.favorites set company_id = p_into where company_id = p_from;
    delete from public.projects  where company_id = p_from;
    delete from public.companies where org_nr = p_from;
    insert into public.admin_audit (admin_id, action, target, details)
    values ((select auth.uid()), 'company_merge', p_from,
      jsonb_build_object('into', p_into, 'projects', n_proj, 'members', n_mem,
                         'items', n_items, 'suppliers', n_sup));
  end if;
  return jsonb_build_object('ok', true, 'dry_run', p_dry_run, 'projects', n_proj,
    'members', n_mem, 'items', n_items, 'suppliers', n_sup);
end $$;

-- Rename a company (the org number is never edited).
create function public.admin_rename_company(p_org text, p_name text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  update public.companies set name = btrim(p_name) where org_nr = p_org;
  insert into public.admin_audit (admin_id, action, target, details)
  values ((select auth.uid()), 'company_rename', p_org, jsonb_build_object('name', btrim(p_name)));
end $$;

-- Overview: one row per company.
create function public.admin_company_overview()
returns table (org_nr text, name text, projects bigint, members bigint, items bigint, last_item_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  return query
  select c.org_nr, c.name,
    (select count(*) from public.projects p where p.company_id = c.org_nr),
    (select count(distinct m.user_id) from public.members m where m.company_id = c.org_nr),
    (select count(*) from public.items i where i.company_id = c.org_nr),
    (select max(i.created_at) from public.items i where i.company_id = c.org_nr)
  from public.companies c order by c.name;
end $$;

-- Read-only detail: projects with members and roles (no lead code hashes).
create function public.admin_company_detail(p_org text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('project', p.id, 'cutoff', p.cutoff,
      'members', (select coalesce(jsonb_agg(jsonb_build_object('name', m.name, 'role', m.role)
                                            order by m.role, m.name), '[]'::jsonb)
                  from public.members m where m.company_id = p.company_id and m.project_id = p.id))
      order by p.id)
    from public.projects p where p.company_id = p_org), '[]'::jsonb);
end $$;

-- Usage numbers plus items per day for the last 30 days (Stockholm time).
create function public.admin_stats() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  return jsonb_build_object(
    'companies', (select count(*) from public.companies),
    'projects',  (select count(*) from public.projects),
    'people',    (select count(distinct user_id) from public.members),
    'items_total', (select count(*) from public.items),
    'items_per_day', (select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'items', d.n)
                                                order by d.day), '[]'::jsonb)
       from (select day, count(*) n from public.items
             where day >= ((now() at time zone 'Europe/Stockholm')::date - 29) group by day) d));
end $$;

-- Only signed-in users may call these; each function also checks is_admin() itself.
revoke all on function public.admin_import_catalog(uuid, jsonb, boolean) from public, anon;
revoke all on function public.admin_promote_supplier(uuid)               from public, anon;
revoke all on function public.admin_merge_companies(text, text, boolean) from public, anon;
revoke all on function public.admin_rename_company(text, text)           from public, anon;
revoke all on function public.admin_company_overview()                   from public, anon;
revoke all on function public.admin_company_detail(text)                 from public, anon;
revoke all on function public.admin_stats()                              from public, anon;
grant execute on function public.admin_import_catalog(uuid, jsonb, boolean) to authenticated;
grant execute on function public.admin_promote_supplier(uuid)               to authenticated;
grant execute on function public.admin_merge_companies(text, text, boolean) to authenticated;
grant execute on function public.admin_rename_company(text, text)           to authenticated;
grant execute on function public.admin_company_overview()                   to authenticated;
grant execute on function public.admin_company_detail(text)                 to authenticated;
grant execute on function public.admin_stats()                              to authenticated;
