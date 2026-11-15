-- accounts_username_login
-- Real accounts: email + username + password. Anonymous sign-in is no longer used.
--   * profiles: username (unique, case-insensitive) and the one company an account belongs to
--   * sign-up with a code: join code -> electrician, company lead code -> lead
--   * sign-up with a company admin code (separate path) -> second admin of that company
--   * create company: new account becomes admin, system makes the admin code (shown once) and lead code.
--     Companies are approved immediately.
--   * username login: the Edge Function `login` looks up the email with login_email() and signs in
--   * admin.html: list users, change roles, remove, disable, delete
-- Clean cut: old anonymous members, roles and favorites are dropped. Items stay as history.

-- 1) Clean cut (the owner account stays)
delete from public.members;
delete from public.company_leads;
delete from public.company_admins;
delete from public.favorites;
delete from auth.users
 where is_anonymous is true and id not in (select user_id from public.admins);

-- 2) Profiles
create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username text not null check (username ~ '^[A-Za-z0-9ÅÄÖåäö._-]{3,20}$'),
  company_id text references public.companies(org_nr) on delete set null,
  created_at timestamptz not null default now()
);
create unique index profiles_username_key on public.profiles (lower(username));
create index profiles_company_idx on public.profiles (company_id);
alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;

create function public.valid_username(u text) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(u, '') ~ '^[A-Za-z0-9ÅÄÖåäö._-]{3,20}$';
$$;
revoke all on function public.valid_username(text) from public, anon, authenticated;

-- 3) Attempts by people who have no account yet
alter table public.code_attempts alter column user_id drop not null;

-- 4) Code lookup (internal). Lead code first, then join code.
create function public.code_target(p_code text)
returns table (kind text, company_id text, project_id text)
language sql stable security definer set search_path = '' as $$
  select 'lead'::text, a.company_id, null::text
    from public.company_access a
   where public.norm_code(p_code) <> '' and a.lead_invite_code = public.norm_code(p_code)
  union all
  select 'member'::text, s.company_id, s.project_id
    from public.project_secrets s
   where public.norm_code(p_code) <> '' and s.join_code = public.norm_code(p_code)
  limit 1;
$$;
revoke all on function public.code_target(text) from public, anon, authenticated;

-- 5) Sign-up check (internal). Returns {ok, role, company_id, company_name, project_id, new_company}
--    or {error}. kind: 'code' (join or lead code), 'admin' (company org nr + admin code), 'company' (new company).
create function public.signup_resolve(p_username text, p_kind text, p_code text, p_company text, p_company_name text)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_user text := btrim(coalesce(p_username, ''));
  v_co text; v_id text; v_kind text; v_status text; v_cname text; v_hash text; v_name text;
begin
  if not public.valid_username(v_user) then return json_build_object('error', 'bad_username'); end if;
  if exists (select 1 from public.profiles p where lower(p.username) = lower(v_user)) then
    return json_build_object('error', 'username_taken');
  end if;
  if public.attempts_blocked() then raise exception 'too_many_attempts'; end if;

  if p_kind = 'code' then
    select t.kind, t.company_id, t.project_id into v_kind, v_co, v_id from public.code_target(p_code) t;
    if v_kind is null then
      perform public.note_failed_attempt();
      return json_build_object('error', 'wrong_code');
    end if;
  elsif p_kind = 'admin' then
    v_co := regexp_replace(coalesce(p_company, ''), '\D', '', 'g');
    if char_length(v_co) = 12 and left(v_co, 2) = '16' then v_co := substr(v_co, 3); end if;
    select a.admin_code_hash into v_hash from public.company_access a where a.company_id = v_co;
    if v_hash is null or public.norm_code(p_code) = ''
       or extensions.crypt(public.norm_code(p_code), v_hash) <> v_hash then
      perform public.note_failed_attempt();
      return json_build_object('error', 'wrong_code');
    end if;
    v_kind := 'admin';
  elsif p_kind = 'company' then
    v_co := regexp_replace(coalesce(p_company, ''), '\D', '', 'g');
    if char_length(v_co) = 12 and left(v_co, 2) = '16' then v_co := substr(v_co, 3); end if;
    v_name := btrim(regexp_replace(coalesce(p_company_name, ''), '\s+', ' ', 'g'));
    if not public.valid_org_nr(v_co) or v_co = '0000000000' then return json_build_object('error', 'bad_org_nr'); end if;
    -- a third digit below 2 means a personal number (sole trader): not stored
    if substr(v_co, 3, 1) < '2' then return json_build_object('error', 'personal_number'); end if;
    if char_length(v_name) not between 2 and 60 then return json_build_object('error', 'bad_company_name'); end if;
    if exists (select 1 from public.companies c where c.org_nr = v_co) then
      return json_build_object('error', 'company_exists');
    end if;
    return json_build_object('ok', true, 'role', 'admin', 'company_id', v_co,
                             'company_name', v_name, 'new_company', true);
  else
    raise exception 'bad_kind';
  end if;

  select c.status, c.name into v_status, v_cname from public.companies c where c.org_nr = v_co;
  if not found then return json_build_object('error', 'wrong_code'); end if;
  if v_status = 'pending' then return json_build_object('error', 'company_pending'); end if;
  if v_status = 'rejected' then return json_build_object('error', 'company_rejected'); end if;
  return json_build_object('ok', true,
    'role', case v_kind when 'member' then 'electrician' else v_kind end,
    'company_id', v_co, 'company_name', v_cname, 'project_id', v_id);
end $$;
revoke all on function public.signup_resolve(text, text, text, text, text) from public, anon, authenticated;

-- Before the account exists: is the username free and is the code right? (nothing is stored)
create function public.signup_precheck(p_username text, p_kind text, p_code text default null,
                                       p_company text default null, p_company_name text default null)
returns json language sql security definer set search_path = '' as $$
  select public.signup_resolve(p_username, p_kind, p_code, p_company, p_company_name);
$$;
revoke all on function public.signup_precheck(text, text, text, text, text) from public;
grant execute on function public.signup_precheck(text, text, text, text, text) to anon, authenticated;

-- After the email is confirmed: check again (this one counts) and create profile and role.
-- A new company also gets its admin code (returned once, stored hashed) and its lead code.
create function public.finish_signup(p_username text, p_kind text, p_code text default null,
                                     p_company text default null, p_company_name text default null)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  r json; v_role text; v_co text; v_id text; v_admin_code text; v_lead_code text;
begin
  if v_uid is null or coalesce((select auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'not_signed_in';
  end if;
  if exists (select 1 from public.profiles p where p.user_id = v_uid) then raise exception 'already_registered'; end if;
  r := public.signup_resolve(p_username, p_kind, p_code, p_company, p_company_name);
  if r ->> 'error' is not null then return r; end if;
  v_role := r ->> 'role'; v_co := r ->> 'company_id'; v_id := r ->> 'project_id';

  if (r ->> 'new_company') is not null then
    insert into public.companies (org_nr, name, status) values (v_co, r ->> 'company_name', 'approved');
    v_admin_code := public.random_code(8);
    v_lead_code := public.random_code(8);
    insert into public.company_access (company_id, admin_code_hash, lead_invite_code)
      values (v_co, extensions.crypt(v_admin_code, extensions.gen_salt('bf')), v_lead_code)
    on conflict (company_id) do update
      set admin_code_hash = excluded.admin_code_hash, lead_invite_code = excluded.lead_invite_code;
  end if;

  insert into public.profiles (user_id, username, company_id) values (v_uid, btrim(p_username), v_co);
  if v_role = 'admin' then
    insert into public.company_admins (company_id, user_id) values (v_co, v_uid) on conflict do nothing;
  elsif v_role = 'lead' then
    insert into public.company_leads (company_id, user_id) values (v_co, v_uid) on conflict do nothing;
  else
    insert into public.members (user_id, company_id, project_id, name, role)
      values (v_uid, v_co, v_id, btrim(p_username), 'electrician') on conflict do nothing;
  end if;
  return json_build_object('ok', true, 'role', v_role, 'company_id', v_co, 'company_name', r ->> 'company_name',
                           'project_id', v_id, 'admin_code', v_admin_code, 'lead_code', v_lead_code);
end $$;
revoke all on function public.finish_signup(text, text, text, text, text) from public, anon;
grant execute on function public.finish_signup(text, text, text, text, text) to authenticated;

-- 6) Old anonymous entry points are gone
drop function public.add_company(text, text, text);
drop function public.claim_company_admin(text, text);
drop function public.join_with_code(text, text);

-- 7) A signed-in account adds another project (or the lead role) with a code. One company per account.
create function public.join_with_code(p_code text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_prof public.profiles;
  v_kind text; v_co text; v_id text; v_status text; v_cname text; v_role text;
begin
  select * into v_prof from public.profiles p where p.user_id = v_uid;
  if not found then raise exception 'no_profile'; end if;
  if public.attempts_blocked() then raise exception 'too_many_attempts'; end if;
  select t.kind, t.company_id, t.project_id into v_kind, v_co, v_id from public.code_target(p_code) t;
  if v_kind is null then
    perform public.note_failed_attempt();
    return json_build_object('error', 'wrong_code');
  end if;
  select c.status, c.name into v_status, v_cname from public.companies c where c.org_nr = v_co;
  if not found then raise exception 'company_not_found'; end if;
  if v_status = 'pending' then raise exception 'company_pending'; end if;
  if v_status = 'rejected' then raise exception 'company_rejected'; end if;
  if v_prof.company_id is not null and v_prof.company_id <> v_co then
    return json_build_object('error', 'other_company');
  end if;
  if v_prof.company_id is null then
    update public.profiles set company_id = v_co where user_id = v_uid;
  end if;

  if v_kind = 'lead' then
    insert into public.company_leads (company_id, user_id) values (v_co, v_uid) on conflict do nothing;
    return json_build_object('kind', 'lead', 'company_id', v_co, 'company_name', v_cname, 'name', v_prof.username);
  end if;
  -- already in: keeps the role (a lead is not turned into an electrician)
  insert into public.members (user_id, company_id, project_id, name, role)
    values (v_uid, v_co, v_id, v_prof.username, 'electrician')
  on conflict (user_id, company_id, project_id) do update set name = excluded.name
  returning role into v_role;
  return json_build_object('kind', 'member', 'company_id', v_co, 'company_name', v_cname, 'project_id', v_id,
                           'name', v_prof.username, 'role', v_role, 'join_code', null);
end $$;
revoke all on function public.join_with_code(text) from public, anon;
grant execute on function public.join_with_code(text) to authenticated;

-- 8) Where this account belongs (login screen and project picker)
create or replace function public.my_access() returns json
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_prof public.profiles;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_prof from public.profiles p where p.user_id = v_uid;
  if not found then return json_build_object('profile', false); end if;
  return json_build_object(
    'profile', true,
    'username', v_prof.username,
    'company_id', v_prof.company_id,
    'company_name', (select c.name from public.companies c where c.org_nr = v_prof.company_id),
    'is_admin', public.is_company_admin(v_prof.company_id),
    'staff', coalesce((select json_agg(x) from (
        select c.org_nr as company_id, c.name as company_name,
               exists (select 1 from public.company_admins a where a.company_id = c.org_nr and a.user_id = v_uid) as admin
          from public.companies c
         where c.status = 'approved'
           and (exists (select 1 from public.company_admins a where a.company_id = c.org_nr and a.user_id = v_uid)
             or exists (select 1 from public.company_leads l where l.company_id = c.org_nr and l.user_id = v_uid))
         order by c.name) x), '[]'::json),
    'projects', coalesce((select json_agg(y) from (
        select m.company_id, c.name as company_name, m.project_id, m.name, m.role
          from public.members m
          join public.companies c on c.org_nr = m.company_id
         where m.user_id = v_uid and c.status = 'approved'
         order by c.name, m.project_id) y), '[]'::json));
end $$;

-- 9) Company admin: new admin code (shown once, stored hashed)
create function public.company_new_admin_code(p_company text) returns text
language plpgsql security definer set search_path = '' as $$
declare v_co text := regexp_replace(coalesce(p_company, ''), '\D', '', 'g'); v_code text;
begin
  if not public.is_company_admin(v_co) then raise exception 'not_company_admin'; end if;
  v_code := public.random_code(8);
  insert into public.company_access (company_id, admin_code_hash)
    values (v_co, extensions.crypt(v_code, extensions.gen_salt('bf')))
  on conflict (company_id) do update set admin_code_hash = excluded.admin_code_hash;
  return v_code;
end $$;
revoke all on function public.company_new_admin_code(text) from public, anon;
grant execute on function public.company_new_admin_code(text) to authenticated;

-- 10) Username login: only the Edge Function (service role) may look up the email
create function public.login_email(p_username text) returns text
language sql stable security definer set search_path = '' as $$
  select u.email::text from public.profiles p join auth.users u on u.id = p.user_id
   where lower(p.username) = lower(btrim(coalesce(p_username, '')));
$$;
revoke all on function public.login_email(text) from public, anon, authenticated;
grant execute on function public.login_email(text) to service_role;

-- 11) App owner: users (admin.html). Every function checks is_admin() itself.
create function public.admin_user_list(p_org text default null)
returns table (user_id uuid, username text, email text, company_id text, is_company_admin boolean,
               is_company_lead boolean, projects jsonb, created_at timestamptz,
               last_sign_in_at timestamptz, disabled boolean, is_owner boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  return query
  select p.user_id, p.username, u.email::text, p.company_id,
    exists (select 1 from public.company_admins a where a.company_id = p.company_id and a.user_id = p.user_id),
    exists (select 1 from public.company_leads l where l.company_id = p.company_id and l.user_id = p.user_id),
    coalesce((select jsonb_agg(jsonb_build_object('project', m.project_id, 'role', m.role) order by m.project_id)
                from public.members m where m.user_id = p.user_id and m.company_id = p.company_id), '[]'::jsonb),
    p.created_at, u.last_sign_in_at,
    (u.banned_until is not null and u.banned_until > now()),
    exists (select 1 from public.admins ad where ad.user_id = p.user_id)
  from public.profiles p join auth.users u on u.id = p.user_id
  where p_org is null or p.company_id = p_org
  order by lower(p.username)
  limit 1000;
end $$;

-- common guard: owner only, never the owner's own account
create function public.admin_user_guard(p_user uuid) returns text
language plpgsql stable security definer set search_path = '' as $$
declare v_co text;
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  if exists (select 1 from public.admins a where a.user_id = p_user) then
    raise exception 'owner account' using errcode = '23514';
  end if;
  select p.company_id into v_co from public.profiles p where p.user_id = p_user;
  if not found then raise exception 'user not found' using errcode = '23503'; end if;
  return v_co;
end $$;
revoke all on function public.admin_user_guard(uuid) from public, anon, authenticated;

-- company level: 'admin', 'lead' (company lead) or 'member' (neither)
create function public.admin_user_company_role(p_user uuid, p_role text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_co text := public.admin_user_guard(p_user);
begin
  if v_co is null then raise exception 'user has no company' using errcode = '23514'; end if;
  if p_role not in ('admin', 'lead', 'member') then raise exception 'bad role' using errcode = '23514'; end if;
  delete from public.company_admins where company_id = v_co and user_id = p_user;
  delete from public.company_leads  where company_id = v_co and user_id = p_user;
  if p_role = 'admin' then
    insert into public.company_admins (company_id, user_id) values (v_co, p_user);
  elsif p_role = 'lead' then
    insert into public.company_leads (company_id, user_id) values (v_co, p_user);
  end if;
  insert into public.admin_audit (admin_id, action, target, details)
  values ((select auth.uid()), 'user_company_role', p_user::text, jsonb_build_object('company', v_co, 'role', p_role));
end $$;

-- project level: 'electrician', 'lead' or 'remove'
create function public.admin_user_project(p_user uuid, p_project text, p_role text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_co text := public.admin_user_guard(p_user); v_id text := upper(btrim(p_project)); v_name text;
begin
  if v_co is null then raise exception 'user has no company' using errcode = '23514'; end if;
  if p_role not in ('electrician', 'lead', 'remove') then raise exception 'bad role' using errcode = '23514'; end if;
  if p_role = 'remove' then
    delete from public.members where user_id = p_user and company_id = v_co and project_id = v_id;
  else
    if not exists (select 1 from public.projects p where p.company_id = v_co and p.id = v_id) then
      raise exception 'project not found' using errcode = '23503';
    end if;
    select p.username into v_name from public.profiles p where p.user_id = p_user;
    insert into public.members (user_id, company_id, project_id, name, role)
      values (p_user, v_co, v_id, v_name, p_role)
    on conflict (user_id, company_id, project_id) do update set role = excluded.role;
  end if;
  insert into public.admin_audit (admin_id, action, target, details)
  values ((select auth.uid()), 'user_project', p_user::text,
          jsonb_build_object('company', v_co, 'project', v_id, 'role', p_role));
end $$;

-- take the user out of their company (account stays, can join another company with a code)
create function public.admin_user_remove(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_co text := public.admin_user_guard(p_user);
begin
  delete from public.members where user_id = p_user;
  delete from public.company_leads where user_id = p_user;
  delete from public.company_admins where user_id = p_user;
  delete from public.favorites where user_id = p_user;
  update public.profiles set company_id = null where user_id = p_user;
  insert into public.admin_audit (admin_id, action, target, details)
  values ((select auth.uid()), 'user_remove', p_user::text, jsonb_build_object('company', v_co));
end $$;

-- disable or enable the account (sessions are ended; an open page can work until its token expires, up to 1 hour)
create function public.admin_user_disable(p_user uuid, p_disabled boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_co text := public.admin_user_guard(p_user);
begin
  update auth.users set banned_until = case when p_disabled then now() + interval '100 years' else null end
   where id = p_user;
  if p_disabled then delete from auth.sessions where user_id = p_user; end if;
  insert into public.admin_audit (admin_id, action, target, details)
  values ((select auth.uid()), case when p_disabled then 'user_disable' else 'user_enable' end,
          p_user::text, jsonb_build_object('company', v_co));
end $$;

-- delete the account. Items stay in the project as history (they only carry the name).
create function public.admin_user_delete(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_co text := public.admin_user_guard(p_user); v_name text;
begin
  select p.username into v_name from public.profiles p where p.user_id = p_user;
  delete from public.members where user_id = p_user;
  delete from public.company_leads where user_id = p_user;
  delete from public.company_admins where user_id = p_user;
  delete from public.favorites where user_id = p_user;
  delete from auth.users where id = p_user;
  insert into public.admin_audit (admin_id, action, target, details)
  values ((select auth.uid()), 'user_delete', p_user::text, jsonb_build_object('company', v_co, 'username', v_name));
end $$;

revoke all on function public.admin_user_list(text) from public, anon;
revoke all on function public.admin_user_company_role(uuid, text) from public, anon;
revoke all on function public.admin_user_project(uuid, text, text) from public, anon;
revoke all on function public.admin_user_remove(uuid) from public, anon;
revoke all on function public.admin_user_disable(uuid, boolean) from public, anon;
revoke all on function public.admin_user_delete(uuid) from public, anon;
grant execute on function public.admin_user_list(text) to authenticated;
grant execute on function public.admin_user_company_role(uuid, text) to authenticated;
grant execute on function public.admin_user_project(uuid, text, text) to authenticated;
grant execute on function public.admin_user_remove(uuid) to authenticated;
grant execute on function public.admin_user_disable(uuid, boolean) to authenticated;
grant execute on function public.admin_user_delete(uuid) to authenticated;
