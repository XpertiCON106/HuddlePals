-- =============================================================================
-- DESTRUCTIVE. FRESH START ONLY. DO NOT RUN AGAINST A DATABASE YOU NEED TO KEEP.
-- =============================================================================
--
-- Removes every app object so schema.sql can be run again from scratch:
-- every table and function in the public schema, and the app's
-- "deposits_storage_*" policies on storage.objects. Objects are found by
-- schema and prefix, not by name, so this works whatever an earlier copy of
-- schema.sql called them.
--
-- Does NOT delete auth.users (existing sign-ins keep working and go through
-- profile setup again), does NOT touch extension-owned functions, and does
-- NOT delete the "deposits" bucket or its files. Empty the bucket through
-- the Storage dashboard: Supabase rejects direct deletes from
-- storage.objects (storage.protect_delete).
--
-- Order: run this file, empty the "deposits" bucket, then run schema.sql.

begin;

do $$
declare
  r record;
begin
  for r in
    select policyname from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and policyname like 'deposits\_storage\_%'
  loop
    execute format('drop policy %I on storage.objects', r.policyname);
  end loop;

  for r in
    select tablename from pg_tables where schemaname = 'public'
  loop
    execute format('drop table if exists public.%I cascade', r.tablename);
  end loop;

  -- Functions returning a table's row type already went with that table.
  for r in
    select p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.prokind = 'f'
       and not exists (
         select 1 from pg_depend d
          where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e'
       )
  loop
    execute format('drop function if exists public.%I(%s) cascade', r.proname, r.args);
  end loop;
end $$;

notify pgrst, 'reload schema';

commit;
