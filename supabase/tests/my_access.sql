-- Rollback test for 20261115190000_my_access. Run in the Supabase SQL editor AFTER applying the migration.
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
create function t.ok(cond boolean, what text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', what; end if;
  raise notice 'ok  %', what;
end $$;
grant execute on all functions in schema t to authenticated;

insert into auth.users (id) values
  ('11000000-0000-0000-0000-000000000000'), ('e1000000-0000-0000-0000-000000000000'),
  ('e3000000-0000-0000-0000-000000000000');
insert into public.companies (org_nr, name, status) values
  ('5560160680', 'Test El AB', 'approved'), ('5566770011', 'Vantar AB', 'pending');
insert into public.projects (company_id, id, lead_code_hash) values
  ('5560160680', 'P1', null), ('5560160680', 'P2', null), ('5566770011', 'P1', null);
insert into public.company_leads (company_id, user_id) values
  ('5560160680', '11000000-0000-0000-0000-000000000000'),
  ('5566770011', '11000000-0000-0000-0000-000000000000');
insert into public.members (user_id, company_id, project_id, name, role) values
  ('e1000000-0000-0000-0000-000000000000', '5560160680', 'P1', 'Erik', 'electrician'),
  ('e1000000-0000-0000-0000-000000000000', '5560160680', 'P2', 'Erik', 'electrician'),
  ('e1000000-0000-0000-0000-000000000000', '5566770011', 'P1', 'Erik', 'electrician');

do $$
declare j json;
begin
  perform t.as_user('e1000000-0000-0000-0000-000000000000');
  j := public.my_access();
  perform t.ok(json_array_length(j->'projects') = 2, 'member sees their 2 projects in approved companies only');
  perform t.ok(json_array_length(j->'staff') = 0, 'member is not staff');
  perform t.as_user('11000000-0000-0000-0000-000000000000');
  j := public.my_access();
  perform t.ok(json_array_length(j->'staff') = 1, 'lead sees only the approved company');
  perform t.ok(json_array_length(j->'projects') = 0, 'lead with no member rows has no projects');
  perform t.as_user('e3000000-0000-0000-0000-000000000000');
  j := public.my_access();
  perform t.ok(json_array_length(j->'staff') = 0 and json_array_length(j->'projects') = 0, 'a stranger sees nothing');
  perform t.as_owner();
  perform t.ok(not has_function_privilege('anon', 'public.my_access()', 'execute'), 'anon cannot call my_access');
end $$;
rollback;
