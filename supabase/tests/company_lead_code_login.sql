-- Rollback test for 20261115140000_company_lead_code_login (needs the migrations before it applied).
-- Run it in the Supabase SQL editor (or psql) AFTER applying the migration. Everything is
-- rolled back at the end; it prints a notice per check and stops at the first failure.
-- It signs in as test users by setting the same claim auth.uid() reads, so it needs a role
-- that can create users in auth.users and switch role (postgres in the SQL editor).

begin;

create schema t;
grant usage on schema t to authenticated;

create function t.as_user(u uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', u::text, true);
  execute 'set local role authenticated';
end $$;
create function t.as_owner() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
-- the statement must fail with a message containing msg
create function t.fails(sql text, msg text) returns void language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    if sqlerrm like '%' || msg || '%' then return; end if;
    raise exception 'FAIL: [%] raised [%], wanted [%]', sql, sqlerrm, msg;
  end;
  raise exception 'FAIL: [%] did not fail, wanted [%]', sql, msg;
end $$;
create function t.ok(cond boolean, what text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', what; end if;
  raise notice 'ok  %', what;
end $$;
grant execute on all functions in schema t to authenticated;

-- people: owner of the app (c0), company admin (a1), leads (l1, l2), electricians (e1, e2), stranger (s1)
insert into auth.users (id) values
  ('c0000000-0000-0000-0000-000000000000'), ('a1000000-0000-0000-0000-000000000000'),
  ('11000000-0000-0000-0000-000000000000'), ('12000000-0000-0000-0000-000000000000'),
  ('e1000000-0000-0000-0000-000000000000'), ('e2000000-0000-0000-0000-000000000000'),
  ('51000000-0000-0000-0000-000000000000');
insert into public.admins (user_id) values ('c0000000-0000-0000-0000-000000000000') on conflict do nothing;

insert into public.companies (org_nr, name, status) values
  ('5560160680', 'Test El AB', 'approved'),
  ('5566770011', 'Andra El AB', 'approved'),
  ('5590123450', 'Vantande AB', 'pending');
insert into public.company_access (company_id, lead_invite_code) values
  ('5560160680', 'LEADAAAA'), ('5566770011', 'LEADBBBB'), ('5590123450', 'LEADPEND')
  on conflict (company_id) do update set lead_invite_code = excluded.lead_invite_code;
insert into public.company_admins (company_id, user_id) values ('5560160680', 'a1000000-0000-0000-0000-000000000000');
insert into public.projects (company_id, id) values
  ('5560160680', 'P1'), ('5560160680', 'P2'), ('5566770011', 'P1');
insert into public.project_secrets (company_id, project_id, join_code) values
  ('5560160680', 'P1', 'AAAAAA'), ('5560160680', 'P2', 'CCCCCC'), ('5566770011', 'P1', 'BBBBBB');

do $$
declare
  OWNER constant uuid := 'c0000000-0000-0000-0000-000000000000';
  A1 constant uuid := 'a1000000-0000-0000-0000-000000000000';
  L1 constant uuid := '11000000-0000-0000-0000-000000000000';
  L2 constant uuid := '12000000-0000-0000-0000-000000000000';
  E1 constant uuid := 'e1000000-0000-0000-0000-000000000000';
  E2 constant uuid := 'e2000000-0000-0000-0000-000000000000';
  S1 constant uuid := '51000000-0000-0000-0000-000000000000';
  r json; c text; i int;
begin
  ------------------------------------------------------------------ every company has a lead code
  perform t.as_owner();
  perform t.ok((select count(*) from public.companies c
                 where not exists (select 1 from public.company_access a where a.company_id = c.org_nr and a.lead_invite_code is not null)) = 0,
               'every company has a lead code');
  perform t.fails($q$insert into public.company_access (company_id, lead_invite_code) values ('5566770011', 'LEADAAAA') on conflict (company_id) do update set lead_invite_code = excluded.lead_invite_code$q$, 'duplicate key');

  ------------------------------------------------------------------ lead code login
  perform t.as_user(L1);
  perform t.fails($q$select public.company_projects('5560160680')$q$, 'not_allowed');
  perform t.fails($q$select public.open_project('5560160680', 'P1', 'Lisa')$q$, 'not_allowed');
  r := public.join_with_code('lead-aaaa', 'Lisa');
  perform t.ok(r->>'kind' = 'lead' and r->>'company_id' = '5560160680' and r->>'company_name' = 'Test El AB'
               and r->>'project_id' is null, 'the lead code signs in as lead of the company (no project yet)');
  perform t.as_user(S1);
  perform t.fails($q$select public.join_with_code('LEADPEND', 'Stina')$q$, 'company_pending');

  ------------------------------------------------------------------ a lead sees and opens every project
  perform t.as_user(L1);
  r := public.company_projects('556016-0680');
  perform t.ok(json_array_length(r) = 2 and r->0->>'id' = 'P1' and r->1->>'id' = 'P2', 'the lead sees every project of the company');
  perform t.ok(not exists (select 1 from json_array_elements(public.company_projects('5560160680')) e where e->>'id' = 'X'), 'no other projects listed');
  perform t.fails($q$select public.company_projects('5566770011')$q$, 'not_allowed');
  perform t.fails($q$select public.open_project('5560160680', 'NOPE', 'Lisa')$q$, 'project_not_found');
  perform t.fails($q$select public.open_project('5566770011', 'P1', 'Lisa')$q$, 'not_allowed');
  r := public.open_project('5560160680', 'p2', 'Lisa');
  perform t.ok(r->>'role' = 'lead' and r->>'project_id' = 'P2', 'a lead opens any project of the company and is lead there');
  perform t.ok(public.is_lead('5560160680', 'P2'), 'is_lead is true in the opened project');
  perform t.ok(not public.is_lead('5560160680', 'P1'), 'but not in a project that was not opened');
  perform t.ok((public.project_join_code('5560160680', 'P2')) is not null, 'the lead reads the join code of the opened project');
  perform t.fails($q$select public.project_join_code('5560160680', 'P1')$q$, 'not_lead');

  ------------------------------------------------------------------ create project
  perform t.fails($q$select public.create_project('5560160680', 'P1', 'Lisa')$q$, 'project_exists');
  perform t.fails($q$select public.create_project('5560160680', 'x', 'Lisa')$q$, 'bad_project_id');
  perform t.fails($q$select public.create_project('5560160680', 'NEW1', '')$q$, 'bad_name');
  perform t.as_user(E1);
  perform t.fails($q$select public.create_project('5560160680', 'NEW1', 'Erik')$q$, 'not_allowed');
  perform t.as_user(L1);
  r := public.create_project('5560160680', 'new1', 'Lisa');
  perform t.ok(r->>'project_id' = 'NEW1' and r->>'role' = 'lead' and char_length(r->>'join_code') = 8, 'a lead creates a project, becomes its lead and gets an 8-character join code');
  perform t.as_user(A1);
  r := public.create_project('5560160680', 'NEW2', 'Anna');
  perform t.ok(r->>'role' = 'lead', 'the company admin can create projects');
  r := public.open_project('5560160680', 'NEW1', 'Anna');
  perform t.ok(r->>'role' = 'lead', 'the company admin can open projects');
  perform t.as_owner();
  perform t.ok(not exists (select 1 from public.projects where lead_code_hash is not null and id in ('NEW1', 'NEW2')), 'new projects have no lead code');

  ------------------------------------------------------------------ member login with the 8-character code
  perform t.as_user(L1);
  c := public.project_join_code('5560160680', 'NEW1');
  perform t.as_user(E1);
  r := public.join_with_code(c, 'Erik');
  perform t.ok(r->>'kind' = 'member' and r->>'project_id' = 'NEW1' and r->>'role' = 'electrician', 'an electrician joins with the new code');
  perform t.as_user(E2);
  r := public.join_with_code('AAAAAA', 'Eva');
  perform t.ok(r->>'project_id' = 'P1' and r->>'role' = 'electrician', 'old 6-character join codes still work');
  perform t.as_user(L1);
  c := public.project_join_code('5560160680', 'P2', true);
  perform t.ok(char_length(c) = 8, 'a rotated join code has 8 characters');

  ------------------------------------------------------------------ wrong codes are limited
  perform t.as_user(S1);
  for i in 1..10 loop
    r := public.join_with_code('ZZZZZZZZ', 'Stina');
    perform t.ok(r->>'error' = 'wrong_code', 'wrong code ' || i || ' is answered, not raised');
  end loop;
  perform t.fails($q$select public.join_with_code('ZZZZZZZZ', 'Stina')$q$, 'too_many_attempts');
  perform t.fails($q$select public.join_with_code('AAAAAA', 'Stina')$q$, 'too_many_attempts');
  perform t.fails($q$select public.claim_company_admin('5560160680', 'whatever')$q$, 'too_many_attempts');
  perform t.as_user(E1);
  r := public.join_with_code('YYYYYYYY', 'Erik');
  perform t.ok(r->>'error' = 'wrong_code', 'another phone is not blocked');
  perform t.as_user(L2);
  r := public.claim_company_admin('5560160680', 'nope');
  perform t.ok(r->>'error' = 'wrong_admin_code', 'a wrong admin code is answered and counted');
  perform t.as_owner();
  perform t.ok((select count(*) from public.code_attempts where user_id = L2) = 1, 'the wrong admin code was counted');

  ------------------------------------------------------------------ owner tools
  perform t.as_user(L1);
  perform t.fails($q$select public.admin_company_lead_code('5560160680')$q$, 'not allowed');
  perform t.as_user(OWNER);
  perform t.ok(public.admin_company_lead_code('5560160680') = 'LEADAAAA', 'the owner reads the lead code');
  perform t.ok(public.admin_company_lead_code('5560160680', true) <> 'LEADAAAA', 'the owner rotates the lead code');

  ------------------------------------------------------------------ cleanup of old entry points, access
  perform t.as_owner();
  perform t.ok((select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('join_project', 'rejoin_project', 'redeem_lead_invite')) = 0, 'old join functions are gone');
  perform t.ok(not has_function_privilege('anon', 'public.join_with_code(text,text)', 'execute'), 'anon cannot call join_with_code');
  perform t.ok(not has_function_privilege('anon', 'public.create_project(text,text,text)', 'execute'), 'anon cannot call create_project');
  perform t.ok(not has_function_privilege('authenticated', 'public.attempts_blocked()', 'execute'), 'the app cannot call attempts_blocked');
  perform t.ok(not has_function_privilege('authenticated', 'public.is_company_staff(text)', 'execute'), 'the app cannot call is_company_staff');
  perform t.ok(not has_table_privilege('authenticated', 'public.code_attempts', 'select'), 'the app cannot read code_attempts');
end $$;

rollback;
