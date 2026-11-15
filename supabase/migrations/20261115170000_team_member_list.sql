-- Team tab: a lead sees every member of the project and can promote or remove members.

-- 1) List members of a project (leads only), with the last time each one added an item.
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
     where m.company_id = v_co and m.project_id = v_id
     order by (m.role = 'lead') desc, lower(m.name);
end $$;

-- 2) Promote a member to lead (leads only).
create or replace function public.project_promote_member(p_company text, p_id text, p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_co text := regexp_replace(coalesce(p_company, ''), '\D', '', 'g');
  v_id text := upper(btrim(p_id));
begin
  if not public.is_lead(v_co, v_id) then raise exception 'not_lead'; end if;
  update public.members set role = 'lead'
   where company_id = v_co and project_id = v_id and user_id = p_user;
  if not found then raise exception 'no_such_member'; end if;
end $$;

-- 3) Remove a member (leads only). Leads cannot be removed, and nobody removes themselves,
--    so the project always keeps its lead. A removed person can join again with the join code.
create or replace function public.project_remove_member(p_company text, p_id text, p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_co text := regexp_replace(coalesce(p_company, ''), '\D', '', 'g');
  v_id text := upper(btrim(p_id));
  v_role text;
begin
  if not public.is_lead(v_co, v_id) then raise exception 'not_lead'; end if;
  select m.role into v_role from public.members m
   where m.company_id = v_co and m.project_id = v_id and m.user_id = p_user;
  if v_role is null then raise exception 'no_such_member'; end if;
  if v_role = 'lead' then raise exception 'cannot_remove_lead'; end if;
  delete from public.members where company_id = v_co and project_id = v_id and user_id = p_user;
end $$;

revoke all on function public.project_members(text, text) from public, anon;
revoke all on function public.project_promote_member(text, text, uuid) from public, anon;
revoke all on function public.project_remove_member(text, text, uuid) from public, anon;
grant execute on function public.project_members(text, text) to authenticated;
grant execute on function public.project_promote_member(text, text, uuid) to authenticated;
grant execute on function public.project_remove_member(text, text, uuid) to authenticated;
