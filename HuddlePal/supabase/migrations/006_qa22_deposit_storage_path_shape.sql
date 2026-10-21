-- QA-22: a member could insert a deposit whose storage_path pointed at
-- another huddle's photo or held '../' segments, which members' apps join onto
-- their local cache folder. A deposit's path must now be
-- '<its huddle id>/<uuid>.jpg', the shape the app has always written. Added
-- NOT VALID so existing rows are not rechecked. Safe to re-run.

begin;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'deposits_storage_path_check') then
    alter table public.deposits add constraint deposits_storage_path_check
      check (storage_path ~* ('^' || huddle_id::text || '/[0-9a-f-]{36}\.jpg$')) not valid;
  end if;
end $$;

commit;
