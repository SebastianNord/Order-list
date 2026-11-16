-- pending_members
-- Joining a project with the join code now creates a request (status 'pending').
-- A pending person has no access to the project until a lead approves, or a company admin or
-- company lead (any lead in the company) approves. Rejecting deletes the request.
--   * members.status: 'approved' (default, so everyone already in stays in) or 'pending'
--   * is_member, is_lead, is_company_member, is_company_lead only count approved rows
--   * project_pending / project_approve_member / project_reject_member (approvers only)
--   * cancel_join_request (the person withdraws their own request)
--   * join_with_code creates pending rows; my_access reports the status
--   * sign-up with a join code is approved at once: the email was just verified with the emailed code
--     (third way to get approved, next to a lead or a company admin)

alter table public.members add column status text not null default 'approved'
  check (status in ('approved', 'pending'));
create index members_pending_idx on public.members (company_id, project_id) where status = 'pending';

-- 1) Access checks only count approved people
create or replace function public.is_member(cid text, pid text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.members m
    where m.company_id = cid and m.project_id = pid and m.user_id = (select auth.uid())
      and m.status = 'approved');
$$;
create or replace function public.is_lead(cid text, pid text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.members m
    where m.company_id = cid and m.project_id = pid and m.user_id = (select auth.uid())
      and m.role = 'lead' and m.status = 'approved');
$$;
create or replace function public.is_company_member(cid text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.members m
    where m.company_id = cid and m.user_id = (select auth.uid()) and m.status = 'approved');
$$;
create or replace function public.is_company_lead(cid text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.members m
    where m.company_id = cid and m.user_id = (select auth.uid()) and m.role = 'lead'
      and m.status = 'approved');
$$;

-- who may approve in a project: a lead of the project, or any company admin or company lead
create function public.can_approve(cid text, pid text) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.is_lead(cid, pid) or public.is_company_staff(cid);
$$;
revoke all on function public.can_approve(text, text) from public, anon;
grant execute on function public.can_approve(text, text) to authenticated;

-- 2) The member list only shows approved people
create or replace function public.project_members(p_company text, p_id text)
returns table (user_id uuid, name text, role text, joined_at timestamptz, last_item_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_co text := regexp_replace(coalesce(p_company, ''), '\D', '', 'g');
  v_id text := upper(btrim(p_id));
begin
  if not public.is_lead(v_co, v_id) then raise exception 'not_lead'; end if;
  return query
    select m.user_id, m.name, m.role, m.joined_at,
           (select max(i.created_at) from public.items i
             where i.company_id = m.company_id and i.project_id = m.project_id and i.by_user = m.user_id)
      from public.members m
     where m.company_id = v_co and m.project_id = v_id and m.status = 'approved'
     order by (m.role = 'lead') desc, lower(m.name);
end $$;

-- 3) Requests waiting for approval
create function public.project_pending(p_company text, p_id text)
returns table (user_id uuid, name text, requested_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_co text := regexp_replace(coalesce(p_company, ''), '\D', '', 'g');
  v_id text := upper(btrim(p_id));
begin
  if not public.can_approve(v_co, v_id) then raise exception 'not_allowed'; end if;
  return query
    select m.user_id, m.name, m.joined_at
      from public.members m
     where m.company_id = v_co and m.project_id = v_id and m.status = 'pending'
     order by m.joined_at;
end $$;

create function public.project_approve_member(p_company text, p_id text, p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_co text := regexp_replace(coalesce(p_company, ''), '\D', '', 'g');
  v_id text := upper(btrim(p_id));
begin
  if not public.can_approve(v_co, v_id) then raise exception 'not_allowed'; end if;
  update public.members set status = 'approved'
   where company_id = v_co and project_id = v_id and user_id = p_user and status = 'pending';
  if not found then raise exception 'no_such_request'; end if;
end $$;

-- reject = delete the request (the person can ask again with the join code)
create function public.project_reject_member(p_company text, p_id text, p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_co text := regexp_replace(coalesce(p_company, ''), '\D', '', 'g');
  v_id text := upper(btrim(p_id));
begin
  if not public.can_approve(v_co, v_id) then raise exception 'not_allowed'; end if;
  delete from public.members
   where company_id = v_co and project_id = v_id and user_id = p_user and status = 'pending';
  if not found then raise exception 'no_such_request'; end if;
end $$;

-- the person withdraws their own request
create function public.cancel_join_request(p_company text, p_id text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  delete from public.members
   where company_id = regexp_replace(coalesce(p_company, ''), '\D', '', 'g')
     and project_id = upper(btrim(p_id))
     and user_id = (select auth.uid()) and status = 'pending';
end $$;

revoke all on function public.project_pending(text, text) from public, anon;
revoke all on function public.project_approve_member(text, text, uuid) from public, anon;
revoke all on function public.project_reject_member(text, text, uuid) from public, anon;
revoke all on function public.cancel_join_request(text, text) from public, anon;
grant execute on function public.project_pending(text, text) to authenticated;
grant execute on function public.project_approve_member(text, text, uuid) to authenticated;
grant execute on function public.project_reject_member(text, text, uuid) to authenticated;
grant execute on function public.cancel_join_request(text, text) to authenticated;

-- 4) Joining with a project join code creates a pending request. An approved person keeps their
--    role and status (a lead is not turned into an electrician, a member is not set back to pending).
create or replace function public.join_with_code(p_code text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_prof public.profiles;
  v_kind text; v_co text; v_id text; v_status text; v_cname text; v_role text; v_mstatus text;
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
  insert into public.members (user_id, company_id, project_id, name, role, status)
    values (v_uid, v_co, v_id, v_prof.username, 'electrician', 'pending')
  on conflict (user_id, company_id, project_id) do update set name = excluded.name
  returning role, status into v_role, v_mstatus;
  return json_build_object('kind', 'member', 'company_id', v_co, 'company_name', v_cname, 'project_id', v_id,
                           'name', v_prof.username, 'role', v_role, 'status', v_mstatus, 'join_code', null);
end $$;

-- 5) Sign-up with a join code: the email was just verified by code, so the person is approved at once
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
    insert into public.members (user_id, company_id, project_id, name, role, status)
      values (v_uid, v_co, v_id, btrim(p_username), 'electrician', 'approved') on conflict do nothing;
  end if;
  return json_build_object('ok', true, 'role', v_role, 'company_id', v_co, 'company_name', r ->> 'company_name',
                           'project_id', v_id, 'admin_code', v_admin_code, 'lead_code', v_lead_code);
end $$;

-- 6) my_access: projects carry the status, so the app can show the waiting screen
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
        select m.company_id, c.name as company_name, m.project_id, m.name, m.role, m.status
          from public.members m
          join public.companies c on c.org_nr = m.company_id
         where m.user_id = v_uid and c.status = 'approved'
         order by c.name, m.project_id) y), '[]'::json));
end $$;

-- 7) Leads and admins who open a project are approved at once (also fixes a pending row they might have)
create or replace function public.open_project(p_company text, p_id text, p_name text) returns json
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
  insert into public.members (user_id, company_id, project_id, name, role, status)
    values ((select auth.uid()), v_co, v_id, v_name, 'lead', 'approved')
  on conflict (user_id, company_id, project_id)
    do update set name = excluded.name, role = 'lead', status = 'approved';
  return json_build_object('kind', 'member', 'company_id', v_co, 'company_name', v_cname, 'project_id', v_id,
                           'name', v_name, 'role', 'lead', 'join_code', null);
end $$;

-- 8) Owner (admin.html) adding someone to a project approves them
create or replace function public.admin_user_project(p_user uuid, p_project text, p_role text) returns void
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
    insert into public.members (user_id, company_id, project_id, name, role, status)
      values (p_user, v_co, v_id, v_name, p_role, 'approved')
    on conflict (user_id, company_id, project_id) do update set role = excluded.role, status = 'approved';
  end if;
  insert into public.admin_audit (admin_id, action, target, details)
  values ((select auth.uid()), 'user_project', p_user::text,
          jsonb_build_object('company', v_co, 'project', v_id, 'role', p_role));
end $$;
