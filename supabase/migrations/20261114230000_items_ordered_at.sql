-- items_ordered_at
-- When an item was marked ordered. Set and cleared by a trigger, so every client
-- gets it the same way. Used to keep a carried-over item visible on the list until
-- the midnight after it was ordered. Existing ordered rows stay null.

alter table public.items add column ordered_at timestamptz;

create function public.items_set_ordered_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.ordered is true and old.ordered is distinct from true then
    new.ordered_at := now();
  elsif new.ordered is not true then
    new.ordered_at := null;
  end if;
  return new;
end $$;

create trigger items_set_ordered_at
  before update of ordered on public.items
  for each row execute function public.items_set_ordered_at();
