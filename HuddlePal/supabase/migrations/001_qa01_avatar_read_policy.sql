-- QA-01: profile photos were readable, and listable through the Storage API,
-- by anyone holding the app's anon key (it ships in the app binary), and by
-- any signed-in stranger. Profile photos are now readable only by their owner
-- and people who share a huddle with them: the same rule as the profile row.
-- Safe to re-run.

begin;

drop policy if exists deposits_storage_read on storage.objects;

-- Signed-in callers only: the anon key ships in the app, so an anon-readable
-- path is a public one (listable through the Storage API).
create policy deposits_storage_read on storage.objects for select to authenticated
  using (
    bucket_id = 'deposits' and (
      (
        (storage.foldername(name))[1] = 'avatars'
        and shares_huddle_with(try_uuid((storage.foldername(name))[2]))
      )
      or (
        try_uuid((storage.foldername(name))[1]) is not null
        and is_huddle_member(try_uuid((storage.foldername(name))[1]))
      )
    )
  );

commit;
