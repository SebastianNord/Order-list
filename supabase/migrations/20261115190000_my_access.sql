-- my_access: after signing in with email + password on a new phone, the app needs to know
-- where this account belongs: companies where it is admin or lead, and projects where it is a member.
create function public.my_access() returns json
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid());
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  return json_build_object(
    'staff', coalesce((select json_agg(x) from (
        select c.org_nr as company_id, c.name as company_name
          from public.companies c
         where c.status = 'approved'
           and (exists (select 1 from public.company_admins a where a.company_id = c.org_nr and a.user_id = v_uid)
             or exists (select 1 from public.company_leads l where l.company_id = c.org_nr and l.user_id = v_uid))
         order by c.name) x), '[]'::json),
    'projects', coalesce((select json_agg(y) from (
        select m.company_id, c.name as company_name, m.project_id, m.name, m.role
          from public.members m
          join public.companies c on c.org_nr = m.company_id
         where m.user_id = v_uid and c.status = 'approved'
         order by c.name, m.project_id) y), '[]'::json));
end $$;
revoke all on function public.my_access() from public, anon;
grant execute on function public.my_access() to authenticated;
