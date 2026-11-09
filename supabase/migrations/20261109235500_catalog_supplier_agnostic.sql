-- catalog_supplier_agnostic
-- The admin catalog is one shared list of articles (article number + name), not tied to a supplier,
-- and has no product link.

-- 1) Keep only the newest row per article number (an article number must now be unique on its own).
delete from public.supplier_catalog c using public.supplier_catalog d
 where c.article_no = d.article_no and (c.updated_at, c.id) < (d.updated_at, d.id);

-- 2) Drop the supplier link and the product link; article number becomes unique on its own.
drop policy catalog_admin_write on public.supplier_catalog;
alter table public.supplier_catalog drop column supplier_id;  -- also drops the old unique key and foreign key
alter table public.supplier_catalog drop column product_url;
alter table public.supplier_catalog add constraint supplier_catalog_article_no_key unique (article_no);
create policy catalog_admin_write on public.supplier_catalog for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- 3) Import without supplier or link: dry run first, last repeated article number wins,
--    bad rows are skipped and counted. Max 5000 rows per call.
drop function public.admin_import_catalog(uuid, jsonb, boolean);
create function public.admin_import_catalog(p_rows jsonb, p_dry_run boolean default true)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare total int; valid int; upd_n int; new_n int;
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'rows must be an array' using errcode = '23514';
  end if;
  total := jsonb_array_length(p_rows);
  if total > 5000 then raise exception 'max 5000 rows per import' using errcode = '23514'; end if;

  with src as (
    select distinct on (btrim(r.article_no)) btrim(r.article_no) as article_no, btrim(r.name) as name
      from jsonb_array_elements(p_rows) with ordinality as e(j, n),
           lateral jsonb_to_record(e.j) as r(article_no text, name text)
     where char_length(btrim(coalesce(r.article_no, ''))) between 1 and 40
       and char_length(btrim(coalesce(r.name, ''))) between 1 and 200
     order by btrim(r.article_no), e.n desc)
  select count(*),
         count(*) filter (where exists (select 1 from public.supplier_catalog c where c.article_no = src.article_no))
    into valid, upd_n from src;
  new_n := valid - upd_n;

  if not p_dry_run then
    with src as (
      select distinct on (btrim(r.article_no)) btrim(r.article_no) as article_no, btrim(r.name) as name
        from jsonb_array_elements(p_rows) with ordinality as e(j, n),
             lateral jsonb_to_record(e.j) as r(article_no text, name text)
       where char_length(btrim(coalesce(r.article_no, ''))) between 1 and 40
         and char_length(btrim(coalesce(r.name, ''))) between 1 and 200
       order by btrim(r.article_no), e.n desc)
    insert into public.supplier_catalog (article_no, name)
    select article_no, name from src
    on conflict (article_no) do update set name = excluded.name, updated_at = now();

    insert into public.admin_audit (admin_id, action, target, details)
    values ((select auth.uid()), 'catalog_import', 'catalog',
      jsonb_build_object('rows', total, 'new', new_n, 'updated', upd_n, 'skipped', total - valid));
  end if;
  return jsonb_build_object('rows', total, 'new', new_n, 'updated', upd_n,
    'skipped', total - valid, 'dry_run', p_dry_run);
end $$;
revoke all on function public.admin_import_catalog(jsonb, boolean) from public, anon;
grant execute on function public.admin_import_catalog(jsonb, boolean) to authenticated;
