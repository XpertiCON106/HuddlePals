-- QA-20: the delete-account edge function now releases the deposit photos a
-- user uploaded before calling auth.admin.deleteUser. The Storage API records
-- the uploader as each object's owner, and where storage.objects.owner still
-- references auth.users that blocks deleting anyone who ever deposited a
-- photo. Service role only. Safe to re-run.

begin;

create or replace function public.release_storage_objects(p_user_id uuid)
returns integer
language sql set search_path = '' as $$
  with released as (
    update storage.objects set owner = null, owner_id = null
     where owner = p_user_id or owner_id = p_user_id::text
    returning 1
  )
  select count(*)::integer from released;
$$;
revoke execute on function public.release_storage_objects(uuid) from public, anon, authenticated;
grant execute on function public.release_storage_objects(uuid) to service_role;

commit;
