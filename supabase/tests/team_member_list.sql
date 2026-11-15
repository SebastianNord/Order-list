-- Rollback test for 20261115170000_team_member_list.
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

-- people: lead (l1), electricians (e1, e2), other project's lead (l2)
insert into auth.users (id) values
  ('11000000-0000-0000-0000-000000000000'), ('e1000000-0000-0000-0000-000000000000'),
  ('e2000000-0000-0000-0000-000000000000'), ('12000000-0000-0000-0000-000000000000');
insert into public.companies (org_nr, name, status) values
  ('5560160680', 'Test El AB', 'approved'), ('5566770011', 'Andra El AB', 'approved');
insert into public.projects (company_id, id, lead_code_hash) values
  ('5560160680', 'P1', extensions.crypt('x', extensions.gen_salt('bf'))),
  ('5566770011', 'P1', extensions.crypt('y', extensions.gen_salt('bf')));
insert into public.members (user_id, company_id, project_id, name, role) values
  ('11000000-0000-0000-0000-000000000000', '5560160680', 'P1', 'Lisa Lead', 'lead'),
  ('e1000000-0000-0000-0000-000000000000', '5560160680', 'P1', 'Erik', 'electrician'),
  ('e2000000-0000-0000-0000-000000000000', '5560160680', 'P1', 'Anna', 'electrician'),
  ('12000000-0000-0000-0000-000000000000', '5566770011', 'P1', 'Other Lead', 'lead'),
  ('e1000000-0000-0000-0000-000000000000', '5566770011', 'P1', 'Erik', 'electrician');

do $$
declare
  L1 constant uuid := '11000000-0000-0000-0000-000000000000';
  L2 constant uuid := '12000000-0000-0000-0000-000000000000';
  E1 constant uuid := 'e1000000-0000-0000-0000-000000000000';
  E2 constant uuid := 'e2000000-0000-0000-0000-000000000000';
  n int;
begin
  -- the item author is set from the signed-in user, so add the item as Erik
  perform t.as_user(E1);
  insert into public.items (company_id, project_id, day, text, key, qty, by_name)
    values ('5560160680', 'P1', current_date, 'kabel', 'kabel', 1, 'Erik');

  -- list
  perform t.as_user(L1);
  select count(*) into n from public.project_members('556016-0680', 'p1');
  perform t.ok(n = 3, 'lead sees all 3 members of the project (not the other company''s)');
  perform t.ok((select name from public.project_members('5560160680', 'P1') limit 1) = 'Lisa Lead', 'leads are listed first');
  perform t.ok((select last_item_at is not null from public.project_members('5560160680', 'P1') where user_id = E1), 'last item time is shown');
  perform t.ok((select last_item_at is null from public.project_members('5560160680', 'P1') where user_id = E2), 'no items gives no last item time');
  perform t.as_user(E1);
  perform t.fails($q$select * from public.project_members('5560160680', 'P1')$q$, 'not_lead');
  perform t.fails($q$select public.project_remove_member('5560160680', 'P1', 'e2000000-0000-0000-0000-000000000000')$q$, 'not_lead');
  perform t.fails($q$select public.project_promote_member('5560160680', 'P1', 'e1000000-0000-0000-0000-000000000000')$q$, 'not_lead');
  perform t.as_user(L2);
  perform t.fails($q$select * from public.project_members('5560160680', 'P1')$q$, 'not_lead');
  perform t.fails($q$select public.project_remove_member('5560160680', 'P1', 'e1000000-0000-0000-0000-000000000000')$q$, 'not_lead');

  -- promote
  perform t.as_user(L1);
  perform t.fails($q$select public.project_promote_member('5560160680', 'P1', '99000000-0000-0000-0000-000000000000')$q$, 'no_such_member');
  perform public.project_promote_member('5560160680', 'P1', E2);
  perform t.as_owner();
  perform t.ok((select role from public.members where user_id = E2 and company_id = '5560160680') = 'lead', 'member promoted to lead');
  perform t.ok((select role from public.members where user_id = E1 and company_id = '5566770011') = 'electrician', 'other company untouched');

  -- remove
  perform t.as_user(L1);
  perform t.fails($q$select public.project_remove_member('5560160680', 'P1', '11000000-0000-0000-0000-000000000000')$q$, 'cannot_remove_lead');
  perform t.fails($q$select public.project_remove_member('5560160680', 'P1', 'e2000000-0000-0000-0000-000000000000')$q$, 'cannot_remove_lead');
  perform public.project_remove_member('5560160680', 'P1', E1);
  perform t.as_owner();
  perform t.ok(not exists (select 1 from public.members where user_id = E1 and company_id = '5560160680'), 'member removed');
  perform t.ok(exists (select 1 from public.members where user_id = E1 and company_id = '5566770011'), 'same person stays in the other company');
  perform t.ok((select count(*) from public.items where by_user = E1) = 1, 'removed member''s items stay');

  -- grants
  perform t.ok(not has_function_privilege('anon', 'public.project_members(text,text)', 'execute'), 'anon cannot list members');
  perform t.ok(not has_function_privilege('anon', 'public.project_remove_member(text,text,uuid)', 'execute'), 'anon cannot remove members');
end $$;

rollback;
