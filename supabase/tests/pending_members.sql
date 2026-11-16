-- Rollback test for 20261116150000_pending_members.
-- Run it in the Supabase SQL editor (or psql) AFTER applying the migration. Everything is
-- rolled back at the end; it prints a notice per check and stops at the first failure.

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

-- people: project lead L1, company lead (not in the project) S1, electricians E1 E2 E3, other company's lead L2
insert into auth.users (id) values
  ('11000000-0000-0000-0000-000000000000'), ('51000000-0000-0000-0000-000000000000'),
  ('e1000000-0000-0000-0000-000000000000'), ('e2000000-0000-0000-0000-000000000000'),
  ('e3000000-0000-0000-0000-000000000000'), ('12000000-0000-0000-0000-000000000000');
insert into public.companies (org_nr, name, status) values
  ('5560160680', 'Test El AB', 'approved'), ('5566770011', 'Andra El AB', 'approved');
insert into public.projects (company_id, id) values ('5560160680', 'P1'), ('5566770011', 'P1');
insert into public.project_secrets (company_id, project_id, join_code) values ('5560160680', 'P1', 'ABCD2345');
insert into public.profiles (user_id, username, company_id) values
  ('11000000-0000-0000-0000-000000000000', 'lisa', '5560160680'),
  ('51000000-0000-0000-0000-000000000000', 'sture', '5560160680'),
  ('e1000000-0000-0000-0000-000000000000', 'erik', '5560160680'),
  ('e2000000-0000-0000-0000-000000000000', 'anna', '5560160680'),
  ('e3000000-0000-0000-0000-000000000000', 'olle', '5560160680'),
  ('12000000-0000-0000-0000-000000000000', 'otto', '5566770011');
insert into public.company_leads (company_id, user_id) values ('5560160680', '51000000-0000-0000-0000-000000000000');
insert into public.members (user_id, company_id, project_id, name, role) values
  ('11000000-0000-0000-0000-000000000000', '5560160680', 'P1', 'lisa', 'lead'),
  ('12000000-0000-0000-0000-000000000000', '5566770011', 'P1', 'otto', 'lead');

do $$
declare
  L1 constant uuid := '11000000-0000-0000-0000-000000000000';
  S1 constant uuid := '51000000-0000-0000-0000-000000000000';
  L2 constant uuid := '12000000-0000-0000-0000-000000000000';
  E1 constant uuid := 'e1000000-0000-0000-0000-000000000000';
  E2 constant uuid := 'e2000000-0000-0000-0000-000000000000';
  E3 constant uuid := 'e3000000-0000-0000-0000-000000000000';
  r json;
begin
  -- joining with the join code gives a pending request
  perform t.as_user(E1);
  r := public.join_with_code('ABCD-2345');
  perform t.ok(r ->> 'status' = 'pending', 'join code creates a pending request');
  perform t.as_user(E2); perform public.join_with_code('abcd2345');
  perform t.as_user(E3); perform public.join_with_code('ABCD2345');
  perform t.as_owner();
  perform t.ok((select count(*) from public.members where status = 'pending') = 3, 'three pending requests');

  -- a pending person has no access
  perform t.as_user(E1);
  perform t.ok(not public.is_member('5560160680', 'P1'), 'pending is not a member');
  perform t.ok(not public.is_company_member('5560160680'), 'pending is not a company member');
  perform t.ok((select count(*) from public.projects) = 0, 'pending cannot read the project');
  perform t.ok((select count(*) from public.members) = 0, 'pending cannot read the member list');
  perform t.ok((r := public.my_access()) is not null and (r -> 'projects' -> 0 ->> 'status') = 'pending', 'my_access reports pending');
  perform t.fails($q$select * from public.project_members('5560160680', 'P1')$q$, 'not_lead');
  perform t.fails($q$select * from public.project_pending('5560160680', 'P1')$q$, 'not_allowed');
  perform t.fails($q$select public.project_approve_member('5560160680', 'P1', 'e1000000-0000-0000-0000-000000000000')$q$, 'not_allowed');

  -- the project lead sees requests, and they are not in the member list
  perform t.as_user(L1);
  perform t.ok((select count(*) from public.project_pending('556016-0680', 'p1')) = 3, 'lead sees 3 requests');
  perform t.ok((select count(*) from public.project_members('5560160680', 'P1')) = 1, 'member list has only approved people');

  -- other company's lead cannot see or decide
  perform t.as_user(L2);
  perform t.fails($q$select * from public.project_pending('5560160680', 'P1')$q$, 'not_allowed');
  perform t.fails($q$select public.project_reject_member('5560160680', 'P1', 'e1000000-0000-0000-0000-000000000000')$q$, 'not_allowed');

  -- approve (project lead)
  perform t.as_user(L1);
  perform public.project_approve_member('5560160680', 'P1', E1);
  perform t.fails($q$select public.project_approve_member('5560160680', 'P1', 'e1000000-0000-0000-0000-000000000000')$q$, 'no_such_request');
  perform t.as_user(E1);
  perform t.ok(public.is_member('5560160680', 'P1'), 'approved person is a member');
  perform t.ok((select count(*) from public.projects) = 1, 'approved person can read the project');
  perform t.ok(not public.is_lead('5560160680', 'P1'), 'approved electrician is not a lead');

  -- approve (company lead who is not in the project)
  perform t.as_user(S1);
  perform t.ok((select count(*) from public.project_pending('5560160680', 'P1')) = 2, 'company lead sees requests');
  perform public.project_approve_member('5560160680', 'P1', E2);
  -- reject deletes the request
  perform public.project_reject_member('5560160680', 'P1', E3);
  perform t.as_owner();
  perform t.ok(not exists (select 1 from public.members where user_id = E3), 'rejected request is gone');
  perform t.ok((select status from public.members where user_id = E2) = 'approved', 'company lead approved a request');

  -- reject and approve cannot touch approved people
  perform t.as_user(L1);
  perform t.fails($q$select public.project_reject_member('5560160680', 'P1', 'e1000000-0000-0000-0000-000000000000')$q$, 'no_such_request');

  -- a company admin can approve too
  perform t.as_owner();
  insert into auth.users (id) values ('a1000000-0000-0000-0000-000000000000');
  insert into public.profiles (user_id, username, company_id) values ('a1000000-0000-0000-0000-000000000000', 'greta', '5560160680');
  insert into public.company_admins (company_id, user_id) values ('5560160680', 'a1000000-0000-0000-0000-000000000000');
  perform t.as_user(E3); perform public.join_with_code('ABCD2345');
  perform t.as_user('a1000000-0000-0000-0000-000000000000');
  perform public.project_approve_member('5560160680', 'P1', E3);
  perform t.as_owner();
  perform t.ok((select status from public.members where user_id = E3) = 'approved', 'company admin approved a request');

  -- joining again does not reset an approved person or a lead
  perform t.as_user(E1);
  r := public.join_with_code('ABCD2345');
  perform t.ok(r ->> 'status' = 'approved', 'approved member stays approved when joining again');

  -- cancel own request
  perform t.as_owner();
  insert into auth.users (id) values ('e4000000-0000-0000-0000-000000000000');
  insert into public.profiles (user_id, username, company_id) values ('e4000000-0000-0000-0000-000000000000', 'nils', '5560160680');
  perform t.as_user('e4000000-0000-0000-0000-000000000000'); perform public.join_with_code('ABCD2345');
  perform public.cancel_join_request('5560160680', 'P1');
  perform t.as_owner();
  perform t.ok(not exists (select 1 from public.members where user_id = 'e4000000-0000-0000-0000-000000000000'), 'person cancelled own request');
  perform t.as_user(E1); perform public.cancel_join_request('5560160680', 'P1');
  perform t.as_owner();
  perform t.ok(exists (select 1 from public.members where user_id = E1 and status = 'approved'), 'cancel does not remove an approved member');

  -- grants
  perform t.ok(not has_function_privilege('anon', 'public.project_pending(text,text)', 'execute'), 'anon cannot list requests');
  perform t.ok(not has_function_privilege('anon', 'public.project_approve_member(text,text,uuid)', 'execute'), 'anon cannot approve');
  perform t.ok(not has_function_privilege('anon', 'public.cancel_join_request(text,text)', 'execute'), 'anon cannot cancel');
end $$;

rollback;
