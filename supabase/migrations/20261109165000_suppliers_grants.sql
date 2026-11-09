-- suppliers_grants
-- 1) Signed-in users get only the four normal privileges on suppliers
--    (the default grants also included TRUNCATE, TRIGGER, REFERENCES, MAINTAIN).
-- 2) projects uses column level grants: let signed-in users read the new
--    default_supplier_id column; the existing update rule (leads only) decides who may change it.

revoke all on public.suppliers from authenticated;
grant select, insert, update, delete on public.suppliers to authenticated;

grant select (default_supplier_id), update (default_supplier_id) on public.projects to authenticated;
