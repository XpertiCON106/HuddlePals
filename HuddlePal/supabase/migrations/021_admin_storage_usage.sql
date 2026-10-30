-- Storage and database usage for the huddlepals.com admin dashboard's
-- "Storage & usage" page: the deposits bucket's size and file count, its
-- size by top-level folder, and the database size. One new read-only
-- function, called by the website's Worker with the service role key. No
-- table changes. Safe to re-run.

begin;

-- Huddle folders are named by huddle id, so they are counted together as
-- "huddles"; any other top-level folder (such as avatars) is listed by name.
create or replace function public.admin_storage_usage()
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_result jsonb;
begin
  with files as (
    select coalesce((o.metadata->>'size')::bigint, 0) as bytes,
           case
             when position('/' in o.name) = 0 then '(top level)'
             when split_part(o.name, '/', 1) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then 'huddles'
             else split_part(o.name, '/', 1)
           end as folder
      from storage.objects o
     where o.bucket_id = 'deposits'
  ), folders as (
    select folder, count(*) as files, sum(bytes) as bytes
      from files group by folder
  )
  select jsonb_build_object(
    'bucket', 'deposits',
    'storage_bytes', coalesce((select sum(bytes) from files), 0),
    'storage_files', (select count(*) from files),
    'folders', coalesce((select jsonb_agg(jsonb_build_object('folder', folder, 'files', files, 'bytes', bytes) order by bytes desc, folder)
                           from folders), '[]'::jsonb),
    'all_buckets_bytes', coalesce((select sum(coalesce((o.metadata->>'size')::bigint, 0)) from storage.objects o), 0),
    'database_bytes', pg_catalog.pg_database_size(pg_catalog.current_database())
  ) into v_result;
  return v_result;
end $$;
revoke execute on function public.admin_storage_usage() from public, anon, authenticated;
grant execute on function public.admin_storage_usage() to service_role;

commit;
