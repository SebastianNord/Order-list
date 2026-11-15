-- Rollback test for 20261115010000_company_admin_and_join_codes.
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

-- people: owner of the app (c0), company admin (a1), electrician (e1, e2), other admin (a2),
-- invited lead (l1), stranger (s1), third-party (x1)
insert into auth.users (id) values
  ('c0000000-0000-0000-0000-000000000000'), ('a1000000-0000-0000-0000-000000000000'),
  ('e1000000-0000-0000-0000-000000000000'), ('e2000000-0000-0000-0000-000000000000'),
  ('a2000000-0000-0000-0000-000000000000'), ('11000000-0000-0000-0000-000000000000'),
  ('51000000-0000-0000-0000-000000000000'), ('b1000000-0000-0000-0000-000000000000');
insert into public.admins (user_id) values ('c0000000-0000-0000-0000-000000000000');

do $$
declare
  OWNER constant uuid := 'c0000000-0000-0000-0000-000000000000';
  A1 constant uuid := 'a1000000-0000-0000-0000-000000000000';
  E1 constant uuid := 'e1000000-0000-0000-0000-000000000000';
  E2 constant uuid := 'e2000000-0000-0000-0000-000000000000';
  A2 constant uuid := 'a2000000-0000-0000-0000-000000000000';
  L1 constant uuid := '11000000-0000-0000-0000-000000000000';
  S1 constant uuid := '51000000-0000-0000-0000-000000000000';
  X1 constant uuid := 'b1000000-0000-0000-0000-000000000000';
  CO  constant text := '5560160680';
  CO2 constant text := '5566770011';
  CO3 constant text := '5590123450';
  r json; jc text; jc2 text; inv text; ac text; n int;
begin
  ------------------------------------------------------------------ backfill
  perform t.ok((select count(*) from public.projects p
                 where not exists (select 1 from public.project_secrets s
                                    where s.company_id = p.company_id and s.project_id = p.id)) = 0,
               'every existing project has a join code');
  perform t.ok((select count(*) from public.companies where status <> 'approved'
                 and created_at < now() - interval '1 second') = 0,
               'existing companies are approved');

  ------------------------------------------------------------------ add_company
  perform t.as_user(A1);
  perform t.fails(format('select public.add_company(%L, %L)', CO, 'Test El AB'), 'bad_admin_code');
  perform t.fails(format('select public.add_company(%L, %L, %L)', CO, 'Test El AB', 'abc'), 'bad_admin_code');
  perform t.fails(format('select public.add_company(%L, %L, %L)', '1234567890', 'Bad AB', 'secret123'), 'bad_org_nr');
  r := public.add_company(CO, 'Test El AB', 'secret123');
  perform t.ok((r->>'created')::boolean and r->>'status' = 'pending', 'new company is created as pending');
  perform t.ok((public.company_role(CO)->>'admin')::boolean, 'creator is company admin');
  perform t.as_user(S1);
  r := public.add_company(CO, 'Other Name', null);
  perform t.ok(not (r->>'created')::boolean and r->>'status' = 'pending',
               'adding an existing org number selects it (status shown, no admin code needed)');
  perform t.ok(not (public.company_role(CO)->>'admin')::boolean, 'a second person does not become admin');

  ------------------------------------------------------------------ pending company
  perform t.as_user(A1);
  perform t.fails(format('select public.join_project(%L, %L, %L, true, %L)', CO, 'P1', 'Anna', 'leadcode1'), 'company_pending');
  perform t.fails(format('select public.company_lead_invite(%L)', CO), 'company_pending');
  perform t.as_user(S1);
  perform t.fails(format('select public.join_project(%L, %L, %L, false, null, %L)', CO, 'P1', 'Stina', 'ABCDEF'), 'company_pending');

  ------------------------------------------------------------------ owner approval
  perform t.as_user(A1);
  perform t.fails(format('select public.admin_set_company_status(%L, %L)', CO, 'approved'), 'not allowed');
  perform t.fails('select * from public.admin_company_overview()', 'not allowed');
  perform t.as_user(OWNER);
  perform t.ok((select status from public.admin_company_overview() where org_nr = CO) = 'pending'
               and (select has_admin from public.admin_company_overview() where org_nr = CO),
               'owner sees the pending company with an admin');
  perform t.fails(format('select public.admin_set_company_status(%L, %L)', CO, 'maybe'), 'bad status');
  perform t.fails(format('select public.admin_set_company_status(%L, %L)', '0000000000', 'rejected'), 'placeholder');
  perform public.admin_set_company_status(CO, 'rejected');
  perform t.as_user(A1);
  perform t.fails(format('select public.join_project(%L, %L, %L, true, %L)', CO, 'P1', 'Anna', 'leadcode1'), 'company_rejected');
  perform t.as_user(OWNER);
  perform public.admin_set_company_status(CO, 'approved');
  perform t.ok((select count(*) from public.admin_audit where action = 'company_status' and target = CO) = 2,
               'status changes are audited');

  ------------------------------------------------------------------ project creation
  perform t.as_user(S1);
  perform t.fails(format('select public.join_project(%L, %L, %L, true, %L)', CO, 'P1', 'Stina', 'leadcode1'), 'not_allowed_to_create');
  perform t.as_user(A1);
  r := public.join_project(CO, 'p1', 'Anna', true, 'leadcode1');
  perform t.ok(r->>'role' = 'lead' and char_length(r->>'join_code') = 6, 'company admin creates a project and gets a join code');
  jc := r->>'join_code';

  ------------------------------------------------------------------ electricians and the join code
  perform t.as_user(E1);
  perform t.fails(format('select public.join_project(%L, %L, %L)', CO, 'P1', 'Erik'), 'wrong_join_code');
  perform t.fails(format('select public.join_project(%L, %L, %L, false, null, %L)', CO, 'P1', 'Erik', 'AAAAAA'), 'wrong_join_code');
  perform t.fails(format('select public.join_project(%L, %L, %L, false, null, %L)', CO, 'NOPE', 'Erik', jc), 'project_not_found');
  r := public.join_project(CO, 'P1', 'Erik', false, null, lower(substr(jc, 1, 3)) || ' - ' || substr(jc, 4));
  perform t.ok(r->>'role' = 'electrician' and r->>'join_code' is null,
               'join code works in lower case with a dash; electrician gets no code back');
  r := public.join_project(CO, 'P1', 'Erik B', false, null, null);
  perform t.ok(r->>'name' = 'Erik B', 'a member signs in again without the code');
  perform t.ok(public.is_member(CO, 'P1'), 'electrician is a member');
  perform t.fails(format('select public.project_join_code(%L, %L)', CO, 'P1'), 'not_lead');
  perform t.fails(format('select public.project_join_code(%L, %L, true)', CO, 'P1'), 'not_lead');

  ------------------------------------------------------------------ lead reads and rotates the join code
  perform t.as_user(A1);
  perform t.ok(public.project_join_code(CO, 'P1') = jc, 'lead reads the join code');
  jc2 := public.project_join_code(CO, 'P1', true);
  perform t.ok(jc2 <> jc and char_length(jc2) = 6, 'lead rotates the join code');
  perform t.as_user(E2);
  perform t.fails(format('select public.join_project(%L, %L, %L, false, null, %L)', CO, 'P1', 'Eva', jc), 'wrong_join_code');
  perform public.join_project(CO, 'P1', 'Eva', false, null, jc2);
  perform t.as_user(E1);
  perform t.ok((public.join_project(CO, 'P1', 'Erik', false, null, null)->>'role') = 'electrician',
               'rotating does not lock out people who are already in');

  ------------------------------------------------------------------ lead of an existing project
  perform t.as_user(L1);
  perform t.fails(format('select public.join_project(%L, %L, %L, true, %L)', CO, 'P1', 'Lasse', 'wrong'), 'wrong_lead_code');
  perform t.ok((public.join_project(CO, 'P1', 'Lasse', true, 'leadcode1')->>'role') = 'lead',
               'lead code still opens an existing project as lead');

  ------------------------------------------------------------------ lead invite code
  perform t.as_user(S1);
  perform t.fails(format('select public.company_lead_invite(%L)', CO), 'not_company_admin');
  perform t.as_user(A1);
  inv := public.company_lead_invite(CO);
  perform t.ok(char_length(inv) = 8 and public.company_lead_invite(CO) = inv, 'admin reads a stable lead invite code');
  perform t.as_user(S1);
  perform t.fails(format('select public.redeem_lead_invite(%L, %L)', CO, 'WRONGCODE'), 'wrong_invite_code');
  perform t.fails(format('select public.redeem_lead_invite(%L, %L)', CO, ''), 'wrong_invite_code');
  perform t.fails(format('select public.join_project(%L, %L, %L, true, %L)', CO, 'P2', 'Stina', 'leadcode2'), 'not_allowed_to_create');
  perform t.ok((public.redeem_lead_invite(CO, lower(inv))->>'invited_lead')::boolean, 'lead redeems the invite code');
  r := public.join_project(CO, 'P2', 'Stina', true, 'leadcode2');
  perform t.ok(r->>'role' = 'lead', 'invited lead creates a project');
  perform t.as_user(A1);
  perform t.ok(public.company_lead_invite(CO, true) <> inv, 'admin rotates the invite code');
  perform t.as_user(X1);
  perform t.fails(format('select public.redeem_lead_invite(%L, %L)', CO, inv), 'wrong_invite_code');

  ------------------------------------------------------------------ admin on another phone
  perform t.as_user(A2);
  perform t.fails(format('select public.claim_company_admin(%L, %L)', CO, 'wrong'), 'wrong_admin_code');
  perform t.fails(format('select public.claim_company_admin(%L, null)', CO), 'wrong_admin_code');
  perform t.ok((public.claim_company_admin(CO, 'secret123')->>'admin')::boolean, 'admin code gives admin on a new phone');
  perform t.ok(char_length(public.company_lead_invite(CO)) = 8, 'the new admin can read the invite code');
  perform t.fails(format('select public.claim_company_admin(%L, %L)', '0000000000', 'anything'), 'wrong_admin_code');

  ------------------------------------------------------------------ company without admin keeps the old rule
  perform t.as_user(S1);
  perform t.ok((public.join_project('0000000000', 'NEW1', 'Stina', true, 'oldrule1')->>'role') = 'lead',
               'a company with no admin: anyone may still start a project');

  ------------------------------------------------------------------ owner hands out an admin code
  perform t.as_user(OWNER);
  ac := public.admin_reset_company_admin_code('0000000000');
  perform t.ok(char_length(ac) = 8, 'owner gets a new admin code once');
  perform t.as_user(X1);
  perform t.ok((public.join_project('0000000000', 'NEW2', 'Xena', true, 'oldrule2')->>'role') = 'lead',
               'until someone claims the code, the company still has no admin and the old rule applies');
  perform t.as_user(A2);
  perform t.fails(format('select public.claim_company_admin(%L, %L)', '0000000000', 'secret123'), 'wrong_admin_code');
  perform t.ok((public.claim_company_admin('0000000000', lower(ac))->>'admin')::boolean, 'owner-issued admin code is claimed');
  perform t.as_user(S1);
  perform t.fails(format('select public.join_project(%L, %L, %L, true, %L)', '0000000000', 'NEW3', 'Stina', 'oldrule3'), 'not_allowed_to_create');
  perform t.ok((public.join_project('0000000000', 'NEW1', 'Stina', true, 'oldrule1')->>'role') = 'lead',
               'a lead can still reopen an existing project with its lead code');
  perform t.as_user(OWNER);
  perform public.admin_reset_company_admin_code('0000000000', true);
  perform t.as_owner();
  perform t.ok((select count(*) from public.company_admins where company_id = '0000000000') = 0,
               'reset with revoke removes the admins');
  perform t.ok((select count(*) from public.admin_audit where action = 'company_admin_code_reset') = 2,
               'resets are audited, and no code is in the log');
  perform t.ok((select count(*) from public.admin_audit where details::text like '%' || ac || '%') = 0, 'code not in audit log');

  ------------------------------------------------------------------ people from before this change
  perform t.as_user('00000000-0000-0000-0000-0000000000a2');
  perform t.ok((public.join_project('0000000000', 'LEG1', 'Old Sparky', false, null, null)->>'role') = 'electrician',
               'an existing member signs in again without a join code');
  perform t.as_user(E2);
  perform t.fails(format('select public.join_project(%L, %L, %L)', '0000000000', 'LEG1', 'Eva'), 'wrong_join_code');
  perform t.as_owner();
  jc := (select join_code from public.project_secrets where company_id = '0000000000' and project_id = 'LEG1');
  perform t.as_user(E2);
  perform t.ok((public.join_project('0000000000', 'LEG1', 'Eva', false, null, jc)->>'role') = 'electrician',
               'a new electrician joins an old project with its backfilled join code');
  perform t.as_user('00000000-0000-0000-0000-0000000000a1');
  perform t.ok(public.project_join_code('0000000000', 'LEG1') = jc, 'the old lead can read the join code');

  ------------------------------------------------------------------ merge moves the new data
  perform t.as_user(X1);
  perform public.add_company(CO2, 'Merge From AB', 'mergecode1');
  perform t.as_user(OWNER);
  perform public.admin_set_company_status(CO2, 'approved');
  perform t.as_user(X1);
  jc := public.join_project(CO2, 'MP1', 'Xena', true, 'mergelead')->>'join_code';
  perform t.as_user(S1);
  perform public.add_company(CO3, 'Merge Into AB', 'intocode1');
  perform t.as_user(OWNER);
  perform public.admin_set_company_status(CO3, 'approved');
  r := public.admin_merge_companies(CO2, CO3, true)::json;
  perform t.ok((r->>'ok')::boolean and (r->>'dry_run')::boolean, 'merge dry run is ok');
  perform public.admin_merge_companies(CO2, CO3, false);
  perform t.as_owner();
  perform t.ok(not exists (select 1 from public.companies where org_nr = CO2), 'merged company is gone');
  perform t.ok((select join_code from public.project_secrets where company_id = CO3 and project_id = 'MP1') = jc,
               'the join code moved with the project');
  perform t.ok(exists (select 1 from public.company_admins where company_id = CO3 and user_id = X1)
               and exists (select 1 from public.company_admins where company_id = CO3 and user_id = S1),
               'admins of both companies are admins of the merged company');
  perform t.ok(not exists (select 1 from public.project_secrets where company_id = CO2), 'no join codes left behind');
  perform t.as_user(E1);
  perform t.ok((public.join_project(CO3, 'MP1', 'Erik', false, null, jc)->>'role') = 'electrician',
               'join code works after the merge');

  ------------------------------------------------------------------ nobody can read the secret tables
  perform t.as_user(A1);
  perform t.fails('select * from public.company_access',  'permission denied');
  perform t.fails('select * from public.project_secrets', 'permission denied');
  perform t.fails('select * from public.company_admins',  'permission denied');
  perform t.fails('select * from public.company_leads',   'permission denied');
  perform t.fails('insert into public.company_admins (company_id, user_id) values (''5560160680'', auth.uid())', 'permission denied');
  perform t.fails('update public.companies set status = ''approved''', 'permission denied');
  perform t.ok((select count(*) from public.companies where status = 'approved') > 0, 'status column is readable');

  ------------------------------------------------------------------ the old functions are gone
  perform t.as_owner();
  perform t.ok((select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'join_project') = 1, 'one join_project');
  perform t.ok((select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'add_company') = 1, 'one add_company');
  perform t.ok(not has_function_privilege('anon', 'public.join_project(text,text,text,boolean,text,text)', 'execute'), 'anon cannot call join_project');
  perform t.ok(not has_function_privilege('authenticated', 'public.random_code(int)', 'execute'), 'the app cannot call random_code');
end $$;

rollback;
