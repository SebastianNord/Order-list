-- company_lead_code_login
-- One code box for everyone:
--   join code (project)  -> member
--   lead code (company)  -> lead: sees every project of the company, opens or creates one
-- The per-project lead code and the "first lead chooses it" rule are gone. Projects are
-- created by company admins and leads, so nobody can claim a project ID by typing it first.
-- Wrong codes are limited (per phone and overall). New and rotated join codes have 8 characters;
-- existing 6-character join codes keep working until they are rotated.

-- 1) Limit on wrong codes. A failed attempt is stored and returned as {"error": ...} (not raised),
--    because a raised error would roll the stored attempt back.
create table public.code_attempts (
  user_id uuid not null,
  at timestamptz not null default now()
);
create index code_attempts_user_at on public.code_attempts (user_id, at);
create index code_attempts_at on public.code_attempts (at);
alter table public.code_attempts enable row level security;
revoke all on public.code_attempts from anon, authenticated;

create function public.attempts_blocked() returns boolean
language sql stable security definer set search_path = '' as $$
  select (select count(*) from public.code_attempts
           where user_id = (select auth.uid()) and at > now() - interval '15 minutes') >= 10
      or (select count(*) from public.code_attempts
           where at > now() - interval '15 minutes') >= 300;
$$;
create function public.note_failed_attempt() returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.code_attempts (user_id) values ((select auth.uid()));
  delete from public.code_attempts where at < now() - interval '1 day';
end $$;
revoke all on function public.attempts_blocked()    from public, anon, authenticated;
revoke all on function public.note_failed_attempt() from public, anon, authenticated;

-- 2) Codes: lead code is unique too, a new join code never equals a lead code, 8 characters
create unique index company_access_lead_code_key on public.company_access (lead_invite_code);

create or replace function public.project_secrets_unique_code() returns trigger
language plpgsql set search_path = '' as $$
begin
  while exists (select 1 from public.project_secrets s
                 where s.join_code = new.join_code
                   and (s.company_id, s.project_id) is distinct from (new.company_id, new.project_id))
     or exists (select 1 from public.company_access a where a.lead_invite_code = new.join_code) loop
    new.join_code := public.random_code(8);
  end loop;
  return new;
end $$;

-- every company gets a lead code (the admin reads it in the app, the app owner in admin.html)
insert into public.company_access (company_id, lead_invite_code)
  select c.org_nr, public.random_code(8) from public.companies c
on conflict (company_id) do update
  set lead_invite_code = coalesce(public.company_access.lead_invite_code, excluded.lead_invite_code);

-- 3) Projects no longer have their own lead code
alter table public.projects alter column lead_code_hash drop not null;

-- 4) Who may open and create projects: company admins and leads who signed in with the lead code
create function public.is_company_staff(cid text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.company_admins a where a.company_id = cid and a.user_id = (select auth.uid()))
      or exists (select 1 from public.company_leads l where l.company_id = cid and l.user_id = (select auth.uid()));
$$;
revoke all on function public.is_company_staff(text) from public, anon, authenticated;

create function public.company_staff_check(p_company text) returns text
language plpgsql stable security definer set search_path = '' as $$
declare v_co text := regexp_replace(coalesce(p_company, ''), '\D', '', 'g'); v_status text;
begin
  if (select auth.uid()) is null then raise exception 'not_signed_in'; end if;
  select c.status into v_status from public.companies c where c.org_nr = v_co;
  if not found then raise exception 'company_not_found'; end if;
  if v_status = 'pending' then raise exception 'company_pending'; end if;
  if v_status = 'rejected' then raise exception 'company_rejected'; end if;
  if not public.is_company_staff(v_co) then raise exception 'not_allowed'; end if;
  return v_co;
end $$;
revoke all on function public.company_staff_check(text) from public, anon, authenticated;

-- 5) One code box. Lead code: company lead. Join code: member of that project.
--    Returns {kind:'lead', company_id, company_name, name} or {kind:'member', ...project...}
--    or {error:'wrong_code'}.
create or replace function public.join_with_code(p_code text, p_name text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_name text := btrim(p_name);
  v_code text := public.norm_code(p_code);
  v_co text; v_id text; v_status text; v_cname text; v_role text;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if char_length(v_name) not between 1 and 30 then raise exception 'bad_name'; end if;
  if public.attempts_blocked() then raise exception 'too_many_attempts'; end if;

  v_co := null;
  if v_code <> '' then
    select a.company_id into v_co from public.company_access a where a.lead_invite_code = v_code;
  end if;
  if v_co is not null then
    select c.status, c.name into v_status, v_cname from public.companies c where c.org_nr = v_co;
    if v_status = 'pending' then raise exception 'company_pending'; end if;
    if v_status = 'rejected' then raise exception 'company_rejected'; end if;
    insert into public.company_leads (company_id, user_id) values (v_co, v_uid) on conflict do nothing;
    return json_build_object('kind', 'lead', 'company_id', v_co, 'company_name', v_cname, 'name', v_name);
  end if;

  select s.company_id, s.project_id into v_co, v_id
    from public.project_secrets s where v_code <> '' and s.join_code = v_code;
  if not found then
    perform public.note_failed_attempt();
    return json_build_object('error', 'wrong_code');
  end if;
  select c.status, c.name into v_status, v_cname from public.companies c where c.org_nr = v_co;
  if not found then raise exception 'company_not_found'; end if;
  if v_status = 'pending' then raise exception 'company_pending'; end if;
  if v_status = 'rejected' then raise exception 'company_rejected'; end if;

  -- a person who is already in keeps their role (a lead is not turned into an electrician)
  insert into public.members (user_id, company_id, project_id, name, role)
    values (v_uid, v_co, v_id, v_name, 'electrician')
  on conflict (user_id, company_id, project_id) do update set name = excluded.name
  returning role into v_role;
  return json_build_object('kind', 'member', 'company_id', v_co, 'company_name', v_cname, 'project_id', v_id,
                           'name', v_name, 'role', v_role, 'join_code', null);
end $$;

-- 6) Leads and admins: list, open and create projects of their company
create function public.company_projects(p_company text) returns json
language plpgsql stable security definer set search_path = '' as $$
declare v_co text := public.company_staff_check(p_company);
begin
  return coalesce((select json_agg(json_build_object('id', p.id,
            'members', (select count(*) from public.members m where m.company_id = p.company_id and m.project_id = p.id))
            order by p.id)
          from public.projects p where p.company_id = v_co), '[]'::json);
end $$;
revoke all on function public.company_projects(text) from public, anon;
grant execute on function public.company_projects(text) to authenticated;

create function public.open_project(p_company text, p_id text, p_name text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_co text := public.company_staff_check(p_company);
  v_id text := upper(btrim(p_id));
  v_name text := btrim(p_name);
  v_cname text;
begin
  if char_length(v_name) not between 1 and 30 then raise exception 'bad_name'; end if;
  if not exists (select 1 from public.projects p where p.company_id = v_co and p.id = v_id) then
    raise exception 'project_not_found';
  end if;
  select c.name into v_cname from public.companies c where c.org_nr = v_co;
  insert into public.members (user_id, company_id, project_id, name, role)
    values ((select auth.uid()), v_co, v_id, v_name, 'lead')
  on conflict (user_id, company_id, project_id) do update set name = excluded.name, role = 'lead';
  return json_build_object('kind', 'member', 'company_id', v_co, 'company_name', v_cname, 'project_id', v_id,
                           'name', v_name, 'role', 'lead', 'join_code', null);
end $$;
revoke all on function public.open_project(text, text, text) from public, anon;
grant execute on function public.open_project(text, text, text) to authenticated;

create function public.create_project(p_company text, p_id text, p_name text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_co text := public.company_staff_check(p_company);
  v_id text := upper(btrim(p_id));
  v_name text := btrim(p_name);
  v_cname text; v_join text;
begin
  if char_length(v_name) not between 1 and 30 then raise exception 'bad_name'; end if;
  if v_id !~ '^[A-Z0-9_-]{2,24}$' then raise exception 'bad_project_id'; end if;
  if exists (select 1 from public.projects p where p.company_id = v_co and p.id = v_id) then
    raise exception 'project_exists';
  end if;
  select c.name into v_cname from public.companies c where c.org_nr = v_co;
  insert into public.projects (company_id, id) values (v_co, v_id);
  insert into public.project_secrets (company_id, project_id, join_code) values (v_co, v_id, public.random_code(8));
  insert into public.members (user_id, company_id, project_id, name, role)
    values ((select auth.uid()), v_co, v_id, v_name, 'lead');
  select s.join_code into v_join from public.project_secrets s where s.company_id = v_co and s.project_id = v_id;
  return json_build_object('kind', 'member', 'company_id', v_co, 'company_name', v_cname, 'project_id', v_id,
                           'name', v_name, 'role', 'lead', 'join_code', v_join);
end $$;
revoke all on function public.create_project(text, text, text) from public, anon;
grant execute on function public.create_project(text, text, text) to authenticated;

-- rotated join codes have 8 characters too
create or replace function public.project_join_code(p_company text, p_id text, p_rotate boolean default false) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_co text := regexp_replace(coalesce(p_company, ''), '\D', '', 'g');
  v_id text := upper(btrim(p_id));
  v_code text;
begin
  if not public.is_lead(v_co, v_id) then raise exception 'not_lead'; end if;
  select s.join_code into v_code from public.project_secrets s where s.company_id = v_co and s.project_id = v_id;
  if v_code is null or p_rotate then
    v_code := public.random_code(8);
    insert into public.project_secrets (company_id, project_id, join_code) values (v_co, v_id, v_code)
      on conflict (company_id, project_id) do update set join_code = excluded.join_code;
    select s.join_code into v_code from public.project_secrets s where s.company_id = v_co and s.project_id = v_id;
  end if;
  return v_code;
end $$;

-- 7) Wrong admin code counts as an attempt (returned, not raised)
create or replace function public.claim_company_admin(p_company text, p_code text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_co text := regexp_replace(coalesce(p_company, ''), '\D', '', 'g');
  v_hash text;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if not exists (select 1 from public.companies c where c.org_nr = v_co) then raise exception 'company_not_found'; end if;
  if public.attempts_blocked() then raise exception 'too_many_attempts'; end if;
  select a.admin_code_hash into v_hash from public.company_access a where a.company_id = v_co;
  -- same answer whether there is no admin code or the code is wrong
  if v_hash is null or public.norm_code(p_code) = '' or extensions.crypt(public.norm_code(p_code), v_hash) <> v_hash then
    perform public.note_failed_attempt();
    return json_build_object('error', 'wrong_admin_code');
  end if;
  insert into public.company_admins (company_id, user_id) values (v_co, v_uid) on conflict do nothing;
  return public.company_role(v_co);
end $$;

-- 8) The app owner reads or rotates a company's lead code (for companies without an admin)
create function public.admin_company_lead_code(p_org text, p_rotate boolean default false) returns text
language plpgsql security definer set search_path = '' as $$
declare v_code text;
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  if not exists (select 1 from public.companies where org_nr = p_org) then
    raise exception 'company not found' using errcode = '23503';
  end if;
  select a.lead_invite_code into v_code from public.company_access a where a.company_id = p_org;
  if v_code is null or p_rotate then
    v_code := public.random_code(8);
    insert into public.company_access (company_id, lead_invite_code) values (p_org, v_code)
      on conflict (company_id) do update set lead_invite_code = excluded.lead_invite_code;
    insert into public.admin_audit (admin_id, action, target, details)
    values ((select auth.uid()), 'company_lead_code', p_org, jsonb_build_object('rotated', p_rotate));
  end if;
  return v_code;
end $$;
revoke all on function public.admin_company_lead_code(text, boolean) from public, anon;
grant execute on function public.admin_company_lead_code(text, boolean) to authenticated;

-- 9) Old entry points are gone
drop function public.join_project(text, text, text, boolean, text, text);
drop function public.rejoin_project(text, text, text);
drop function public.redeem_lead_invite(text, text);
