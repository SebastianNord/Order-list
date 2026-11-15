-- company_admin_and_join_codes
-- Company admin, manual company approval, lead invite code, project join code.
--
-- Roles (not the same as the app owner in admin.html, which uses public.admins):
--   company admin    created the company or claimed it with the admin code. Creates
--                    projects, gives out the lead invite code.
--   invited lead     redeemed the company's lead invite code. Creates projects.
--   lead             knows a project's lead code (as before). Runs that project.
--   electrician      joins an existing project with its join code.
--
-- A new company starts as 'pending'. Nobody can join a project in it until the app owner
-- approves it in admin.html. Existing companies are 'approved'.
-- A company without any admin (the placeholder 0000000000 and companies from before this
-- migration) keeps the old rule for creating projects, until the owner hands out an admin
-- code with admin_reset_company_admin_code.

-- 1) Approval status (readable by everyone, like the rest of companies)
alter table public.companies
  add column status text not null default 'approved'
  check (status in ('pending', 'approved', 'rejected'));
grant select (status) on public.companies to authenticated;

-- 2) Secrets and roles: no direct access, only through the functions below
create table public.company_access (
  company_id text primary key references public.companies(org_nr) on delete cascade,
  admin_code_hash text,
  lead_invite_code text
);
create table public.company_admins (
  company_id text not null references public.companies(org_nr) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (company_id, user_id)
);
create table public.company_leads (
  company_id text not null references public.companies(org_nr) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (company_id, user_id)
);
-- No foreign key to projects on purpose: admin_merge_companies re-creates project rows.
create table public.project_secrets (
  company_id text not null,
  project_id text not null,
  join_code text not null,
  primary key (company_id, project_id)
);
alter table public.company_access  enable row level security;
alter table public.company_admins  enable row level security;
alter table public.company_leads   enable row level security;
alter table public.project_secrets enable row level security;
revoke all on public.company_access, public.company_admins, public.company_leads,
              public.project_secrets from anon, authenticated;

-- 3) Code helpers (not callable from the app)
create function public.random_code(n int) returns text
language plpgsql volatile set search_path = '' as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- no 0/O, 1/I
  b bytea := extensions.gen_random_bytes(n);
  r text := '';
begin
  for i in 0 .. n - 1 loop
    r := r || substr(alphabet, (get_byte(b, i) % 32) + 1, 1);
  end loop;
  return r;
end $$;
create function public.norm_code(c text) returns text
language sql immutable set search_path = '' as $$
  select upper(regexp_replace(coalesce(c, ''), '[^A-Za-z0-9]', '', 'g'));
$$;
revoke all on function public.random_code(int) from public, anon, authenticated;
revoke all on function public.norm_code(text)  from public, anon, authenticated;

-- Existing projects get a join code
insert into public.project_secrets (company_id, project_id, join_code)
select p.company_id, p.id, public.random_code(6) from public.projects p
on conflict do nothing;

-- 4) Role checks
create function public.is_company_admin(cid text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.company_admins a
    where a.company_id = cid and a.user_id = (select auth.uid()));
$$;
revoke all on function public.is_company_admin(text) from public, anon;
grant execute on function public.is_company_admin(text) to authenticated;

-- What the signed-in user is in a company (for the screens)
create function public.company_role(p_company text) returns json
language plpgsql stable security definer set search_path = '' as $$
declare v_co text := regexp_replace(coalesce(p_company, ''), '\D', '', 'g'); v_status text; v_uid uuid := (select auth.uid());
begin
  select c.status into v_status from public.companies c where c.org_nr = v_co;
  if not found then raise exception 'company_not_found'; end if;
  return json_build_object(
    'status', v_status,
    'has_admin', exists (select 1 from public.company_admins a where a.company_id = v_co),
    'admin', exists (select 1 from public.company_admins a where a.company_id = v_co and a.user_id = v_uid),
    'invited_lead', exists (select 1 from public.company_leads l where l.company_id = v_co and l.user_id = v_uid));
end $$;
revoke all on function public.company_role(text) from public, anon;
grant execute on function public.company_role(text) to authenticated;

-- 5) add_company: the person who adds a new company becomes its admin and chooses the admin code
drop function public.add_company(text, text);
create function public.add_company(p_org text, p_name text, p_admin_code text default null)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_org text := regexp_replace(coalesce(p_org, ''), '\D', '', 'g');
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_row public.companies;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if char_length(v_org) = 12 and left(v_org, 2) = '16' then v_org := substr(v_org, 3); end if;
  if not public.valid_org_nr(v_org) or v_org = '0000000000' then raise exception 'bad_org_nr'; end if;
  -- a third digit below 2 means a personal number (sole trader): not stored
  if substr(v_org, 3, 1) < '2' then raise exception 'personal_number'; end if;
  select * into v_row from public.companies c where c.org_nr = v_org;
  if found then
    return json_build_object('org_nr', v_row.org_nr, 'name', v_row.name, 'created', false, 'status', v_row.status);
  end if;
  if char_length(v_name) not between 2 and 60 then raise exception 'bad_company_name'; end if;
  if char_length(public.norm_code(p_admin_code)) < 6 then raise exception 'bad_admin_code'; end if;
  insert into public.companies (org_nr, name, status) values (v_org, v_name, 'pending')
    on conflict (org_nr) do nothing returning * into v_row;
  if not found then
    select * into v_row from public.companies c where c.org_nr = v_org;
    return json_build_object('org_nr', v_row.org_nr, 'name', v_row.name, 'created', false, 'status', v_row.status);
  end if;
  insert into public.company_access (company_id, admin_code_hash)
    values (v_org, extensions.crypt(public.norm_code(p_admin_code), extensions.gen_salt('bf')));
  insert into public.company_admins (company_id, user_id) values (v_org, v_uid);
  return json_build_object('org_nr', v_row.org_nr, 'name', v_row.name, 'created', true, 'status', v_row.status);
end $$;
revoke all on function public.add_company(text, text, text) from public, anon;
grant execute on function public.add_company(text, text, text) to authenticated;

-- Admin on a new phone: company + admin code (case and dashes do not matter, like the other codes)
create function public.claim_company_admin(p_company text, p_code text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_co text := regexp_replace(coalesce(p_company, ''), '\D', '', 'g');
  v_hash text;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if not exists (select 1 from public.companies c where c.org_nr = v_co) then raise exception 'company_not_found'; end if;
  select a.admin_code_hash into v_hash from public.company_access a where a.company_id = v_co;
  -- same error whether there is no admin code or the code is wrong
  if v_hash is null or public.norm_code(p_code) = '' or extensions.crypt(public.norm_code(p_code), v_hash) <> v_hash then
    raise exception 'wrong_admin_code';
  end if;
  insert into public.company_admins (company_id, user_id) values (v_co, v_uid) on conflict do nothing;
  return public.company_role(v_co);
end $$;
revoke all on function public.claim_company_admin(text, text) from public, anon;
grant execute on function public.claim_company_admin(text, text) to authenticated;

-- 6) Lead invite code (company level). Admin reads or rotates it, a lead redeems it.
create function public.company_lead_invite(p_company text, p_rotate boolean default false) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_co text := regexp_replace(coalesce(p_company, ''), '\D', '', 'g');
  v_status text; v_code text;
begin
  if not public.is_company_admin(v_co) then raise exception 'not_company_admin'; end if;
  select c.status into v_status from public.companies c where c.org_nr = v_co;
  if v_status is distinct from 'approved' then raise exception 'company_pending'; end if;
  select a.lead_invite_code into v_code from public.company_access a where a.company_id = v_co;
  if v_code is null or p_rotate then
    v_code := public.random_code(8);
    insert into public.company_access (company_id, lead_invite_code) values (v_co, v_code)
      on conflict (company_id) do update set lead_invite_code = excluded.lead_invite_code;
  end if;
  return v_code;
end $$;
revoke all on function public.company_lead_invite(text, boolean) from public, anon;
grant execute on function public.company_lead_invite(text, boolean) to authenticated;

create function public.redeem_lead_invite(p_company text, p_code text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_co text := regexp_replace(coalesce(p_company, ''), '\D', '', 'g');
  v_status text; v_code text;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select c.status into v_status from public.companies c where c.org_nr = v_co;
  if not found then raise exception 'company_not_found'; end if;
  if v_status = 'pending' then raise exception 'company_pending'; end if;
  if v_status = 'rejected' then raise exception 'company_rejected'; end if;
  select a.lead_invite_code into v_code from public.company_access a where a.company_id = v_co;
  if v_code is null or public.norm_code(p_code) = '' or public.norm_code(p_code) <> v_code then
    raise exception 'wrong_invite_code';
  end if;
  insert into public.company_leads (company_id, user_id) values (v_co, v_uid) on conflict do nothing;
  return public.company_role(v_co);
end $$;
revoke all on function public.redeem_lead_invite(text, text) from public, anon;
grant execute on function public.redeem_lead_invite(text, text) to authenticated;

-- 7) Project join code: only leads of the project can read or rotate it
create function public.project_join_code(p_company text, p_id text, p_rotate boolean default false) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_co text := regexp_replace(coalesce(p_company, ''), '\D', '', 'g');
  v_id text := upper(btrim(p_id));
  v_code text;
begin
  if not public.is_lead(v_co, v_id) then raise exception 'not_lead'; end if;
  select s.join_code into v_code from public.project_secrets s where s.company_id = v_co and s.project_id = v_id;
  if v_code is null or p_rotate then
    v_code := public.random_code(6);
    insert into public.project_secrets (company_id, project_id, join_code) values (v_co, v_id, v_code)
      on conflict (company_id, project_id) do update set join_code = excluded.join_code;
  end if;
  return v_code;
end $$;
revoke all on function public.project_join_code(text, text, boolean) from public, anon;
grant execute on function public.project_join_code(text, text, boolean) to authenticated;

-- 8) join_project: approved company, join code for electricians, invite or admin to create a project
drop function public.join_project(text, text, text, boolean, text);
create function public.join_project(
  p_company text, p_id text, p_name text,
  p_lead boolean default false, p_lead_code text default null, p_join_code text default null)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_co text := regexp_replace(coalesce(p_company, ''), '\D', '', 'g');
  v_id text := upper(btrim(p_id));
  v_name text := btrim(p_name);
  v_role text := 'electrician';
  v_hash text;
  v_status text;
  v_join text;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select c.status into v_status from public.companies c where c.org_nr = v_co;
  if not found then raise exception 'company_not_found'; end if;
  if v_status = 'pending' then raise exception 'company_pending'; end if;
  if v_status = 'rejected' then raise exception 'company_rejected'; end if;
  if v_id !~ '^[A-Z0-9_-]{2,24}$' then raise exception 'bad_project_id'; end if;
  if char_length(v_name) not between 1 and 30 then raise exception 'bad_name'; end if;

  select p.lead_code_hash into v_hash from public.projects p where p.company_id = v_co and p.id = v_id;
  if not found then
    if not p_lead or coalesce(char_length(p_lead_code), 0) < 4 then raise exception 'project_not_found'; end if;
    -- a company with an admin: only the admin or an invited lead may start a project
    if exists (select 1 from public.company_admins a where a.company_id = v_co)
       and not public.is_company_admin(v_co)
       and not exists (select 1 from public.company_leads l where l.company_id = v_co and l.user_id = v_uid) then
      raise exception 'not_allowed_to_create';
    end if;
    insert into public.projects (company_id, id, lead_code_hash)
      values (v_co, v_id, extensions.crypt(p_lead_code, extensions.gen_salt('bf')));
    insert into public.project_secrets (company_id, project_id, join_code)
      values (v_co, v_id, public.random_code(6));
    v_role := 'lead';
  elsif p_lead then
    if p_lead_code is null or extensions.crypt(p_lead_code, v_hash) <> v_hash then raise exception 'wrong_lead_code'; end if;
    v_role := 'lead';
  elsif not exists (select 1 from public.members m
                    where m.user_id = v_uid and m.company_id = v_co and m.project_id = v_id) then
    -- a person already in the project may sign in again without the join code
    select s.join_code into v_join from public.project_secrets s where s.company_id = v_co and s.project_id = v_id;
    if v_join is null or public.norm_code(p_join_code) <> v_join then raise exception 'wrong_join_code'; end if;
  end if;

  insert into public.members (user_id, company_id, project_id, name, role)
    values (v_uid, v_co, v_id, v_name, v_role)
  on conflict (user_id, company_id, project_id) do update set name = excluded.name, role = excluded.role;

  if v_role = 'lead' then
    insert into public.project_secrets (company_id, project_id, join_code)
      values (v_co, v_id, public.random_code(6)) on conflict do nothing;
    select s.join_code into v_join from public.project_secrets s where s.company_id = v_co and s.project_id = v_id;
  else
    v_join := null;
  end if;
  return json_build_object('company_id', v_co, 'project_id', v_id, 'name', v_name, 'role', v_role, 'join_code', v_join);
end $$;
revoke all on function public.join_project(text, text, text, boolean, text, text) from public, anon;
grant execute on function public.join_project(text, text, text, boolean, text, text) to authenticated;

-- 9) App owner tools (admin.html)
drop function public.admin_company_overview();
create function public.admin_company_overview()
returns table (org_nr text, name text, projects bigint, members bigint, items bigint,
               last_item_at timestamptz, status text, has_admin boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  return query
  select c.org_nr, c.name,
    (select count(*) from public.projects p where p.company_id = c.org_nr),
    (select count(distinct m.user_id) from public.members m where m.company_id = c.org_nr),
    (select count(*) from public.items i where i.company_id = c.org_nr),
    (select max(i.created_at) from public.items i where i.company_id = c.org_nr),
    c.status,
    exists (select 1 from public.company_admins a where a.company_id = c.org_nr),
    c.created_at
  from public.companies c order by (c.status = 'pending') desc, c.name;
end $$;
revoke all on function public.admin_company_overview() from public, anon;
grant execute on function public.admin_company_overview() to authenticated;

create function public.admin_set_company_status(p_org text, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_status not in ('pending', 'approved', 'rejected') then
    raise exception 'bad status' using errcode = '23514';
  end if;
  if p_org = '0000000000' and p_status <> 'approved' then
    raise exception 'the placeholder company stays approved' using errcode = '23514';
  end if;
  update public.companies set status = p_status where org_nr = p_org;
  if not found then raise exception 'company not found' using errcode = '23503'; end if;
  insert into public.admin_audit (admin_id, action, target, details)
  values ((select auth.uid()), 'company_status', p_org, jsonb_build_object('status', p_status));
end $$;
revoke all on function public.admin_set_company_status(text, text) from public, anon;
grant execute on function public.admin_set_company_status(text, text) to authenticated;

-- New admin code for a company (the owner hands it to the right person). The code is shown
-- once and is not stored in clear text. p_revoke_admins removes the current admins.
create function public.admin_reset_company_admin_code(p_org text, p_revoke_admins boolean default false)
returns text language plpgsql security definer set search_path = '' as $$
declare v_code text := public.random_code(8);
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  if not exists (select 1 from public.companies where org_nr = p_org) then
    raise exception 'company not found' using errcode = '23503';
  end if;
  insert into public.company_access (company_id, admin_code_hash)
    values (p_org, extensions.crypt(v_code, extensions.gen_salt('bf')))
  on conflict (company_id) do update set admin_code_hash = excluded.admin_code_hash;
  if p_revoke_admins then delete from public.company_admins where company_id = p_org; end if;
  insert into public.admin_audit (admin_id, action, target, details)
  values ((select auth.uid()), 'company_admin_code_reset', p_org,
          jsonb_build_object('revoked_admins', p_revoke_admins));
  return v_code;
end $$;
revoke all on function public.admin_reset_company_admin_code(text, boolean) from public, anon;
grant execute on function public.admin_reset_company_admin_code(text, boolean) to authenticated;

-- Merge now also moves join codes, admins and invited leads.
create or replace function public.admin_merge_companies(p_from text, p_into text, p_dry_run boolean default true)
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
    insert into public.project_secrets (company_id, project_id, join_code)
      select p_into, project_id, join_code from public.project_secrets where company_id = p_from
    on conflict do nothing;
    delete from public.project_secrets where company_id = p_from;
    insert into public.company_admins (company_id, user_id, created_at)
      select p_into, user_id, created_at from public.company_admins where company_id = p_from
    on conflict do nothing;
    insert into public.company_leads (company_id, user_id, created_at)
      select p_into, user_id, created_at from public.company_leads where company_id = p_from
    on conflict do nothing;
    update public.members   set company_id = p_into where company_id = p_from;
    update public.items     set company_id = p_into where company_id = p_from;
    update public.favorites set company_id = p_into where company_id = p_from;
    delete from public.projects  where company_id = p_from;
    delete from public.companies where org_nr = p_from;   -- also removes the old company's access row and roles
    insert into public.admin_audit (admin_id, action, target, details)
    values ((select auth.uid()), 'company_merge', p_from,
      jsonb_build_object('into', p_into, 'projects', n_proj, 'members', n_mem,
                         'items', n_items, 'suppliers', n_sup));
  end if;
  return jsonb_build_object('ok', true, 'dry_run', p_dry_run, 'projects', n_proj,
    'members', n_mem, 'items', n_items, 'suppliers', n_sup);
end $$;
