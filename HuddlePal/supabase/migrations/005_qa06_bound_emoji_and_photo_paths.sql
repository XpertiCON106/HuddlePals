-- QA-06: two fields clients write directly had no server-side bound: a
-- huddle's emoji (any keeper can PATCH it) and a profile's photo_paths (the
-- app allows 3). Added NOT VALID so existing rows are never rechecked; every
-- new write is. Safe to re-run.

begin;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'huddles_emoji_check') then
    alter table public.huddles add constraint huddles_emoji_check
      check (char_length(emoji) between 1 and 16) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_photo_paths_check') then
    alter table public.profiles add constraint profiles_photo_paths_check
      check (jsonb_typeof(photo_paths) = 'array' and jsonb_array_length(photo_paths) <= 3) not valid;
  end if;
end $$;

commit;
