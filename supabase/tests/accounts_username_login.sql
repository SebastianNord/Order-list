-- Rollback test for 20261116100000_accounts_username_login. Run in the Supabase SQL editor AFTER applying the migration.
begin;
create schema t;
grant usage on schema t to authenticated, anon;
create function t.as_user(u uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', u::text, true);
  execute 'set local role authenticated';
end $$;
create function t.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';
end $$;
create function t.as_owner() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
create function t.ok(cond boolean, what text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', what; end if;
  raise notice 'ok  %', what;
end $$;
create function t.fails(sql text, what text) returns void language plpgsql as $$
begin
  begin execute sql; exception when others then raise notice 'ok  % (%)', what, sqlerrm; return; end;
  raise exception 'FAIL: % should have raised', what;
end $$;
create function t.cnt(q text) returns bigint language plpgsql security definer as $$
declare n bigint;
begin execute 'select count(*) from (' || q || ') x' into n; return n; end $$;
grant execute on all functions in schema t to authenticated, anon;

insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000000', 'a@test.se'),
  ('b1000000-0000-0000-0000-000000000000', 'b@test.se'),
  ('c1000000-0000-0000-0000-000000000000', 'c@test.se'),
  ('d1000000-0000-0000-0000-000000000000', 'd@test.se'),
  ('e1000000-0000-0000-0000-000000000000', 'e@test.se'),
  ('0e000000-0000-0000-0000-000000000000', 'owner@test.se');
insert into public.admins (user_id) values ('0e000000-0000-0000-0000-000000000000');

do $$
declare r json; adm text; lead text; join_code text;
begin
  -- anyone can check a username and a code before the account exists
  perform t.as_anon();
  r := public.signup_precheck('anna', 'company', null, '556016-0680', 'Test El AB');
  perform t.ok((r->>'ok')::boolean, 'anon precheck: new company is possible');
  r := public.signup_precheck('an', 'company', null, '5560160680', 'Test El AB');
  perform t.ok(r->>'error' = 'bad_username', 'username too short');
  r := public.signup_precheck('anna', 'company', null, '5560160681', 'Test El AB');
  perform t.ok(r->>'error' = 'bad_org_nr', 'bad checksum');
  r := public.signup_precheck('anna', 'company', null, '5560160680', 'X');
  perform t.ok(r->>'error' = 'bad_company_name', 'company name too short');
  r := public.signup_precheck('anna', 'code', 'NOSUCH12');
  perform t.ok(r->>'error' = 'wrong_code', 'wrong code');
  perform t.fails($q$select public.finish_signup('anna', 'company', null, '5560160680', 'Test El AB')$q$, 'anon cannot finish sign-up');
  perform t.fails($q$select public.my_access()$q$, 'anon has no my_access') ;

  -- 1) create company: new account becomes admin, codes returned once
  perform t.as_user('a1000000-0000-0000-0000-000000000000');
  r := public.finish_signup('Anna', 'company', null, '556016-0680', 'Test El AB');
  perform t.ok((r->>'ok')::boolean and r->>'role' = 'admin', 'company created, creator is admin');
  adm := r->>'admin_code'; lead := r->>'lead_code';
  perform t.ok(char_length(adm) = 8 and char_length(lead) = 8, 'admin code and lead code returned');
  perform t.ok((select status from public.companies where org_nr = '5560160680') = 'approved', 'company approved immediately');
  perform t.ok((public.my_access()->>'is_admin')::boolean, 'my_access: admin');
  perform t.fails($q$select public.finish_signup('Anna2', 'company', null, '5560160680', 'Test El AB')$q$, 'second profile for same account');
  perform t.as_owner();
  perform t.ok((select admin_code_hash from public.company_access where company_id = '5560160680') <> adm, 'admin code is hashed');

  -- same org number again, and the same username in other case
  perform t.as_user('b1000000-0000-0000-0000-000000000000');
  r := public.finish_signup('Bertil', 'company', null, '5560160680', 'Test El AB');
  perform t.ok(r->>'error' = 'company_exists', 'org number can only be stored once');
  r := public.finish_signup('ANNA', 'code', lead);
  perform t.ok(r->>'error' = 'username_taken', 'username unique, case-insensitive');

  -- project and join code (as admin)
  perform t.as_user('a1000000-0000-0000-0000-000000000000');
  perform public.create_project('5560160680', 'P1', 'Anna');
  join_code := public.project_join_code('5560160680', 'P1');

  -- 2) electrician with join code
  perform t.as_user('b1000000-0000-0000-0000-000000000000');
  r := public.finish_signup('Bertil', 'code', join_code);
  perform t.ok(r->>'role' = 'electrician' and r->>'project_id' = 'P1', 'join code makes an electrician');
  perform t.ok(t.cnt('select 1 from public.members where user_id = ''b1000000-0000-0000-0000-000000000000'' and name = ''Bertil''') = 1, 'member row uses the username');

  -- 3) lead with lead code
  perform t.as_user('c1000000-0000-0000-0000-000000000000');
  r := public.finish_signup('Cecilia', 'code', lead);
  perform t.ok(r->>'role' = 'lead', 'lead code makes a lead');
  perform t.ok(json_array_length(public.my_access()->'staff') = 1, 'lead is staff of the company');

  -- 4) second admin with the admin code (separate path), wrong code first
  perform t.as_user('d1000000-0000-0000-0000-000000000000');
  r := public.finish_signup('David', 'admin', 'WRONGCODE');
  perform t.ok(r->>'error' = 'wrong_code', 'wrong admin code');
  r := public.finish_signup('David', 'admin', adm);
  perform t.ok(r->>'role' = 'admin', 'admin code makes a second admin');
  perform t.ok(public.is_company_admin('5560160680'), 'David is company admin');

  -- admin code does not work as a join/lead code and vice versa
  perform t.as_user('e1000000-0000-0000-0000-000000000000');
  r := public.finish_signup('Emil', 'code', adm);
  perform t.ok(r->>'error' = 'wrong_code', 'admin code is not a join code');

  -- 5) join another project with a code while signed in; other company is refused
  perform t.as_owner();
  insert into public.companies (org_nr, name, status) values ('5566770011', 'Other AB', 'approved');
  insert into public.projects (company_id, id) values ('5566770011', 'X1');
  insert into public.project_secrets (company_id, project_id, join_code) values ('5566770011', 'X1', 'OTHERCO1');
  perform t.as_user('b1000000-0000-0000-0000-000000000000');
  r := public.join_with_code('OTHERCO1');
  perform t.ok(r->>'error' = 'other_company', 'one company per account');
  perform t.as_user('a1000000-0000-0000-0000-000000000000');
  perform public.create_project('5560160680', 'P2', 'Anna');
  r := public.join_with_code(public.project_join_code('5560160680', 'P2'));
  perform t.ok(r->>'kind' = 'member', 'signed-in account joins a second project');
end $$;

-- admin code handling by the company admin
do $$
declare c text;
begin
  perform t.as_user('a1000000-0000-0000-0000-000000000000');
  c := public.company_new_admin_code('5560160680');
  perform t.ok(char_length(c) = 8, 'company admin gets a new admin code');
  perform t.as_user('b1000000-0000-0000-0000-000000000000');
  perform t.fails($q$select public.company_new_admin_code('5560160680')$q$, 'electrician cannot make an admin code');
end $$;

-- owner tools
do $$
declare n int; r json;
begin
  perform t.as_user('b1000000-0000-0000-0000-000000000000');
  perform t.fails($q$select * from public.admin_user_list()$q$, 'non-owner cannot list users');
  perform t.fails($q$select public.admin_user_delete('c1000000-0000-0000-0000-000000000000')$q$, 'non-owner cannot delete users');
  perform t.as_user('0e000000-0000-0000-0000-000000000000');
  select count(*) into n from public.admin_user_list('5560160680');
  perform t.ok(n = 4, 'owner lists the 4 users of the company');
  perform t.ok((select (projects->0->>'project') from public.admin_user_list('5560160680') where username = 'Bertil') = 'P1', 'user list shows projects');
  perform public.admin_user_company_role('b1000000-0000-0000-0000-000000000000', 'lead');
  perform t.ok((select is_company_lead from public.admin_user_list('5560160680') where username = 'Bertil'), 'owner makes Bertil company lead');
  perform public.admin_user_project('b1000000-0000-0000-0000-000000000000', 'P1', 'lead');
  perform t.ok(t.cnt('select 1 from public.members where user_id = ''b1000000-0000-0000-0000-000000000000'' and project_id = ''P1'' and role = ''lead''') = 1, 'owner makes Bertil project lead');
  perform public.admin_user_project('b1000000-0000-0000-0000-000000000000', 'P1', 'remove');
  perform t.ok(t.cnt('select 1 from public.members where user_id = ''b1000000-0000-0000-0000-000000000000'' and project_id = ''P1''') = 0, 'owner removes Bertil from project');
  perform t.fails($q$select public.admin_user_project('b1000000-0000-0000-0000-000000000000', 'NOPE', 'lead')$q$, 'unknown project refused');
  perform public.admin_user_disable('c1000000-0000-0000-0000-000000000000', true);
  perform t.ok((select disabled from public.admin_user_list('5560160680') where username = 'Cecilia'), 'owner disables Cecilia');
  perform public.admin_user_disable('c1000000-0000-0000-0000-000000000000', false);
  perform t.ok(not (select disabled from public.admin_user_list('5560160680') where username = 'Cecilia'), 'owner enables Cecilia');
  perform public.admin_user_remove('d1000000-0000-0000-0000-000000000000');
  perform t.ok(t.cnt('select 1 from public.profiles where user_id = ''d1000000-0000-0000-0000-000000000000'' and company_id is null') = 1
               and t.cnt('select 1 from public.company_admins where user_id = ''d1000000-0000-0000-0000-000000000000''') = 0, 'owner removes David from the company');
  perform public.admin_user_delete('c1000000-0000-0000-0000-000000000000');
  perform t.ok(t.cnt('select 1 from auth.users where id = ''c1000000-0000-0000-0000-000000000000''') = 0
               and t.cnt('select 1 from public.profiles where user_id = ''c1000000-0000-0000-0000-000000000000''') = 0, 'owner deletes Cecilia');
  perform t.fails($q$select public.admin_user_delete('0e000000-0000-0000-0000-000000000000')$q$, 'the owner account cannot be changed here');
  perform t.ok(t.cnt('select 1 from public.admin_audit where action like ''user_%''') = 7, 'all 7 user changes are audited');
  perform t.as_owner();
  perform t.ok(not has_function_privilege('anon', 'public.admin_user_list(text)', 'execute'), 'anon cannot list users');
  perform t.ok(not has_function_privilege('authenticated', 'public.login_email(text)', 'execute'), 'only the service role may look up an email');
  perform t.ok(has_function_privilege('service_role', 'public.login_email(text)', 'execute'), 'service role can look up an email');
  perform t.ok(public.login_email('anna') = 'a@test.se', 'username (any case) finds the email');
  perform t.ok(public.login_email('nobody') is null, 'unknown username finds nothing');
end $$;
rollback;
