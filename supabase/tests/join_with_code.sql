-- Rollback test for 20261115120000_join_with_code (needs 20261115010000 applied first).
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

-- people: lead (l1), electricians (e1, e2, e3), stranger (s1)
insert into auth.users (id) values
  ('11000000-0000-0000-0000-000000000000'), ('e1000000-0000-0000-0000-000000000000'),
  ('e2000000-0000-0000-0000-000000000000'), ('e3000000-0000-0000-0000-000000000000'),
  ('51000000-0000-0000-0000-000000000000');

insert into public.companies (org_nr, name, status) values
  ('5560160680', 'Test El AB', 'approved'),
  ('5566770011', 'Andra El AB', 'approved'),
  ('5590123450', 'Vantande AB', 'pending');
insert into public.projects (company_id, id, lead_code_hash) values
  ('5560160680', 'P1',  extensions.crypt('leadcode1', extensions.gen_salt('bf'))),
  ('5566770011', 'P1',  extensions.crypt('leadcode2', extensions.gen_salt('bf'))),
  ('5560160680', 'P2',  extensions.crypt('leadcode3', extensions.gen_salt('bf'))),
  ('5590123450', 'PEN', extensions.crypt('leadcode4', extensions.gen_salt('bf')));
insert into public.project_secrets (company_id, project_id, join_code) values
  ('5560160680', 'P1', 'AAAAAA'), ('5566770011', 'P1', 'BBBBBB'),
  ('5560160680', 'P2', 'CCCCCC'), ('5590123450', 'PEN', 'DDDDDD');
insert into public.members (user_id, company_id, project_id, name, role) values
  ('11000000-0000-0000-0000-000000000000', '5560160680', 'P1', 'Lisa Lead', 'lead');

do $$
declare
  L1 constant uuid := '11000000-0000-0000-0000-000000000000';
  E1 constant uuid := 'e1000000-0000-0000-0000-000000000000';
  E2 constant uuid := 'e2000000-0000-0000-0000-000000000000';
  E3 constant uuid := 'e3000000-0000-0000-0000-000000000000';
  r json; c text;
begin
  ------------------------------------------------------------------ unique join codes
  perform t.as_owner();
  -- a clash on insert gets a fresh code instead of failing
  insert into public.projects (company_id, id, lead_code_hash)
    values ('5566770011', 'P9', extensions.crypt('x', extensions.gen_salt('bf')));
  insert into public.project_secrets (company_id, project_id, join_code) values ('5566770011', 'P9', 'AAAAAA');
  select join_code into c from public.project_secrets where company_id = '5566770011' and project_id = 'P9';
  perform t.ok(c <> 'AAAAAA', 'a clashing join code is replaced on insert');
  -- a clash on update (rotate) too
  update public.project_secrets set join_code = 'BBBBBB' where company_id = '5560160680' and project_id = 'P2';
  select join_code into c from public.project_secrets where company_id = '5560160680' and project_id = 'P2';
  perform t.ok(c <> 'BBBBBB', 'a clashing join code is replaced on update');
  perform t.ok((select count(*) = count(distinct join_code) from public.project_secrets), 'all join codes are unique');
  update public.project_secrets set join_code = 'CCCCCC' where company_id = '5560160680' and project_id = 'P2';

  ------------------------------------------------------------------ join_with_code
  perform t.as_user(E1);
  perform t.fails($q$select public.join_with_code('ZZZZZZ', 'Erik')$q$, 'wrong_join_code');
  perform t.fails($q$select public.join_with_code('', 'Erik')$q$, 'wrong_join_code');
  perform t.fails($q$select public.join_with_code('AAAAAA', '')$q$, 'bad_name');
  perform t.fails($q$select public.join_with_code('DDDDDD', 'Erik')$q$, 'company_pending');
  r := public.join_with_code('a-aa aaa', 'Erik');
  perform t.ok(r->>'company_id' = '5560160680' and r->>'project_id' = 'P1' and r->>'role' = 'electrician'
               and r->>'company_name' = 'Test El AB', 'code alone finds company and project (case and dashes ignored)');
  perform t.ok((r->>'join_code') is null, 'the join code is not returned to an electrician');
  r := public.join_with_code('BBBBBB', 'Erik');
  perform t.ok(r->>'company_id' = '5566770011', 'the same code text belongs to one project only');
  perform t.as_owner();
  perform t.ok((select count(*) from public.members where user_id = E1) = 2, 'joined two projects, two member rows');
  -- a lead who enters the join code stays lead
  perform t.as_user(L1);
  r := public.join_with_code('AAAAAA', 'Lisa L');
  perform t.ok(r->>'role' = 'lead', 'a lead keeps the lead role');

  ------------------------------------------------------------------ rejoin_project
  -- E1 is Erik in P1 of both companies (from above), E2 has never joined anything
  perform t.as_user(E2);
  perform t.fails($q$select public.rejoin_project('P2', 'Erik')$q$, 'rejoin_not_found');
  perform t.fails($q$select public.rejoin_project('P1', 'Nobody')$q$, 'rejoin_not_found');
  perform t.fails($q$select public.rejoin_project('P1', 'Lisa Lead')$q$, 'rejoin_not_found');
  perform t.fails($q$select public.rejoin_project('PEN', 'Erik')$q$, 'rejoin_not_found');
  perform t.fails($q$select public.rejoin_project('x', 'Erik')$q$, 'bad_project_id');
  r := public.rejoin_project(' p1 ', 'erik');
  perform t.ok(r->'choose' is not null and json_array_length(r->'choose') = 2,
               'same project ID and name in two companies: the caller must choose');
  r := public.rejoin_project('P1', 'Erik', '556016-0680');
  perform t.ok(r->>'company_id' = '5560160680' and r->>'role' = 'electrician' and r->>'name' = 'Erik',
               'choosing a company joins it as electrician on a new phone');
  perform t.as_owner();
  perform t.ok(exists (select 1 from public.members where user_id = E2 and company_id = '5560160680' and project_id = 'P1'
                         and role = 'electrician'), 'member row created for the new phone');
  perform t.ok(not exists (select 1 from public.members where user_id = E2 and company_id = '5566770011'), 'nothing joined in the other company');

  -- unique name in one company: no choice needed
  perform t.as_user(E3);
  perform t.fails($q$select public.rejoin_project('P2', 'Erik')$q$, 'rejoin_not_found');
  perform t.as_user(E1);
  r := public.join_with_code('CCCCCC', 'Eva');
  perform t.as_user(E3);
  r := public.rejoin_project('P2', 'Eva');
  perform t.ok(r->>'company_id' = '5560160680' and r->>'project_id' = 'P2', 'a single match joins directly');

  -- a lead on the same phone keeps the lead role
  perform t.as_user(L1);
  r := public.rejoin_project('P1', 'Lisa Lead');
  perform t.ok(r->>'role' = 'lead', 'a lead on their own phone stays lead');

  -- not signed in / anon
  perform t.as_owner();
  perform t.ok(not has_function_privilege('anon', 'public.join_with_code(text,text)', 'execute'), 'anon cannot call join_with_code');
  perform t.ok(not has_function_privilege('anon', 'public.rejoin_project(text,text,text)', 'execute'), 'anon cannot call rejoin_project');
  perform t.ok(not has_function_privilege('authenticated', 'public.project_secrets_unique_code()', 'execute'), 'the app cannot call the trigger function');
  perform t.ok(not has_table_privilege('authenticated', 'public.project_secrets', 'select'), 'the app still cannot read project_secrets');
end $$;

rollback;
