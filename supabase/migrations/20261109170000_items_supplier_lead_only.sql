-- items_supplier_lead_only
-- Only a lead of the project may set or change an item's supplier.
-- Not enforced for: system actions without a signed-in user (admin SQL), and
-- cascades such as "supplier deleted -> item tag cleared" (trigger depth > 1).

create function public.items_supplier_lead_only()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if pg_trigger_depth() > 1 then
    return new;
  end if;
  if (select auth.uid()) is null then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.supplier_id is not null and not public.is_lead(new.company_id, new.project_id) then
      raise exception 'only leads can set an item supplier' using errcode = '42501';
    end if;
  elsif new.supplier_id is distinct from old.supplier_id
        and not public.is_lead(new.company_id, new.project_id) then
    raise exception 'only leads can set an item supplier' using errcode = '42501';
  end if;
  return new;
end $$;

revoke all on function public.items_supplier_lead_only() from public, anon, authenticated;

create trigger items_supplier_lead_only
  before insert or update of supplier_id on public.items
  for each row execute function public.items_supplier_lead_only();
