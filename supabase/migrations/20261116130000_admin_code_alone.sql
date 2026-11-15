-- admin_code_alone
-- A company admin code now finds the company by itself: sign-up with an admin code needs no org number.
-- The code is random (8 characters, 40 bits) and stored as a SHA-256 digest with a unique index.
-- Wrong codes are still limited (per account, and 300 in total). Old bcrypt admin codes cannot be
-- looked up by code alone, so they stop working: the owner makes a new admin code per company in
-- admin.html (Companies tab, New admin code), or an admin does it under Company codes.

alter table public.company_access add column admin_code_digest text;
create unique index company_access_admin_digest_key on public.company_access (admin_code_digest);
update public.company_access set admin_code_hash = null;

create function public.admin_code_digest(c text) returns text
language sql immutable set search_path = '' as $$
  select encode(extensions.digest(public.norm_code(c), 'sha256'), 'hex');
$$;
revoke all on function public.admin_code_digest(text) from public, anon, authenticated;

-- 'admin' kind: the code alone decides the company (p_company is ignored)
create or replace function public.signup_resolve(p_username text, p_kind text, p_code text, p_company text, p_company_name text)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_user text := btrim(coalesce(p_username, ''));
  v_co text; v_id text; v_kind text; v_status text; v_cname text; v_name text;
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
    if public.norm_code(p_code) <> '' then
      select a.company_id into v_co from public.company_access a
       where a.admin_code_digest = public.admin_code_digest(p_code);
    end if;
    if v_co is null then
      perform public.note_failed_attempt();
      return json_build_object('error', 'wrong_code');
    end if;
    v_kind := 'admin';
  elsif p_kind = 'company' then
    v_co := regexp_replace(coalesce(p_company, ''), '\D', '', 'g');
    if char_length(v_co) = 12 and left(v_co, 2) = '16' then v_co := substr(v_co, 3); end if;
    v_name := btrim(regexp_replace(coalesce(p_company_name, ''), '\s+', ' ', 'g'));
    if not public.valid_org_nr(v_co) or v_co = '0000000000' then return json_build_object('error', 'bad_org_nr'); end if;
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

-- new company: store the admin code as digest
create or replace function public.finish_signup(p_username text, p_kind text, p_code text default null,
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
    insert into public.company_access (company_id, admin_code_digest, lead_invite_code)
      values (v_co, public.admin_code_digest(v_admin_code), v_lead_code)
    on conflict (company_id) do update
      set admin_code_digest = excluded.admin_code_digest, lead_invite_code = excluded.lead_invite_code;
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

create or replace function public.company_new_admin_code(p_company text) returns text
language plpgsql security definer set search_path = '' as $$
declare v_co text := regexp_replace(coalesce(p_company, ''), '\D', '', 'g'); v_code text;
begin
  if not public.is_company_admin(v_co) then raise exception 'not_company_admin'; end if;
  v_code := public.random_code(8);
  insert into public.company_access (company_id, admin_code_digest) values (v_co, public.admin_code_digest(v_code))
  on conflict (company_id) do update set admin_code_digest = excluded.admin_code_digest;
  return v_code;
end $$;

create or replace function public.admin_reset_company_admin_code(p_org text, p_revoke_admins boolean default false)
returns text language plpgsql security definer set search_path = '' as $$
declare v_code text := public.random_code(8);
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  if not exists (select 1 from public.companies where org_nr = p_org) then
    raise exception 'company not found' using errcode = '23503';
  end if;
  insert into public.company_access (company_id, admin_code_digest) values (p_org, public.admin_code_digest(v_code))
  on conflict (company_id) do update set admin_code_digest = excluded.admin_code_digest;
  if p_revoke_admins then delete from public.company_admins where company_id = p_org; end if;
  insert into public.admin_audit (admin_id, action, target, details)
  values ((select auth.uid()), 'company_admin_code_reset', p_org,
          jsonb_build_object('revoked_admins', p_revoke_admins));
  return v_code;
end $$;
