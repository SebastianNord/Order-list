-- join_with_code
-- Simpler login for electricians:
--   first time:  name + the project's join code (the code alone finds company and project)
--   returning:   project ID + name (any phone); company is only asked when several match
-- Leads and company admins keep using join_project.

-- 1) Join codes become unique across all companies.
--    A trigger picks a new code if a clash would happen (new project, rotate, merge).
create function public.project_secrets_unique_code() returns trigger
language plpgsql set search_path = '' as $$
begin
  while exists (select 1 from public.project_secrets s
                 where s.join_code = new.join_code
                   and (s.company_id, s.project_id) is distinct from (new.company_id, new.project_id)) loop
    new.join_code := public.random_code(6);
  end loop;
  return new;
end $$;
revoke all on function public.project_secrets_unique_code() from public, anon, authenticated;

create trigger project_secrets_unique_code
  before insert or update of join_code on public.project_secrets
  for each row execute function public.project_secrets_unique_code();

-- Existing clashes: keep the oldest row's code, give the others a new one
with ranked as (
  select ctid as rid,
         row_number() over (partition by join_code order by company_id, project_id) as rn
  from public.project_secrets
)
update public.project_secrets s set join_code = public.random_code(6)
  from ranked r where s.ctid = r.rid and r.rn > 1;

create unique index project_secrets_join_code_key on public.project_secrets (join_code);

-- 2) First time: name + join code
create function public.join_with_code(p_code text, p_name text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_name text := btrim(p_name);
  v_code text := public.norm_code(p_code);
  v_co text; v_id text; v_status text; v_cname text; v_role text;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if char_length(v_name) not between 1 and 30 then raise exception 'bad_name'; end if;
  select s.company_id, s.project_id into v_co, v_id
    from public.project_secrets s where v_code <> '' and s.join_code = v_code;
  if not found then raise exception 'wrong_join_code'; end if;
  select c.status, c.name into v_status, v_cname from public.companies c where c.org_nr = v_co;
  if not found then raise exception 'company_not_found'; end if;
  if v_status = 'pending' then raise exception 'company_pending'; end if;
  if v_status = 'rejected' then raise exception 'company_rejected'; end if;

  -- a person who is already in keeps their role (a lead is not turned into an electrician)
  insert into public.members (user_id, company_id, project_id, name, role)
    values (v_uid, v_co, v_id, v_name, 'electrician')
  on conflict (user_id, company_id, project_id) do update set name = excluded.name
  returning role into v_role;
  return json_build_object('company_id', v_co, 'company_name', v_cname, 'project_id', v_id,
                           'name', v_name, 'role', v_role, 'join_code', null);
end $$;
revoke all on function public.join_with_code(text, text) from public, anon;
grant execute on function public.join_with_code(text, text) to authenticated;

-- 3) Returning: project ID + name. Works on any phone, but only for a name that is already an
--    electrician in that project (a lead's name never matches: leads use their lead code).
--    If the project ID matches in several companies, the caller gets the list and calls again
--    with p_company.
create function public.rejoin_project(p_id text, p_name text, p_company text default null) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_id text := upper(btrim(p_id));
  v_name text := btrim(p_name);
  v_pick text := regexp_replace(coalesce(p_company, ''), '\D', '', 'g');
  v_hits jsonb; v_co text; v_cname text; v_role text;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if char_length(v_name) not between 1 and 30 then raise exception 'bad_name'; end if;
  if v_id !~ '^[A-Z0-9_-]{2,24}$' then raise exception 'bad_project_id'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('org_nr', c.org_nr, 'name', c.name) order by c.name), '[]'::jsonb)
    into v_hits
    from public.companies c
   where c.status = 'approved'
     and (v_pick = '' or c.org_nr = v_pick)
     and exists (select 1 from public.members m
                  where m.company_id = c.org_nr and m.project_id = v_id
                    and (m.user_id = v_uid
                         or (m.role = 'electrician' and lower(btrim(m.name)) = lower(v_name))));
  if jsonb_array_length(v_hits) = 0 then raise exception 'rejoin_not_found'; end if;
  if jsonb_array_length(v_hits) > 1 then
    return json_build_object('choose', v_hits);
  end if;
  v_co := v_hits->0->>'org_nr';
  v_cname := v_hits->0->>'name';

  insert into public.members (user_id, company_id, project_id, name, role)
    values (v_uid, v_co, v_id, v_name, 'electrician')
  on conflict (user_id, company_id, project_id) do update set name = excluded.name
  returning role into v_role;
  return json_build_object('company_id', v_co, 'company_name', v_cname, 'project_id', v_id,
                           'name', v_name, 'role', v_role, 'join_code', null);
end $$;
revoke all on function public.rejoin_project(text, text, text) from public, anon;
grant execute on function public.rejoin_project(text, text, text) to authenticated;
