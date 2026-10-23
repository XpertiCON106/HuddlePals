-- Removing a reported photo while keeping it for NCMEC. Federal law (18
-- U.S.C. 2258A(h)) has the operator preserve what it reports to the
-- CyberTipline for a year, but deleting a photo's row by hand loses the only
-- pointers to its encrypted file. remove_reported_photo() does it in one
-- transaction: it copies what's needed to find and open the photo into
-- preserved_photos, then deletes the photo from its huddle (its reactions and
-- comments go with it). The encrypted file stays in Storage. Run it from the
-- SQL editor; the app can't call it. Safe to re-run.

begin;

create table if not exists public.preserved_photos (
  id uuid primary key default gen_random_uuid(),
  -- The removed deposit. No foreign keys: the rows they'd point at are gone,
  -- or may go (a huddle, an account), and this must outlive them.
  deposit_id uuid not null,
  huddle_id uuid,
  author_id uuid,
  day_key text,
  caption text,
  -- The encrypted file, still in Storage (bucket "deposits").
  storage_path text not null,
  -- The photo key sealed with the huddle key, as the deposit row held it.
  wrapped_photo_key text not null,
  -- The photo's own key from the newest report that carried one: opens the
  -- file with tools/decrypt_reported_photo.
  photo_key text,
  -- Every report that pointed at the photo (their deposit_id is null now).
  report_ids uuid[] not null default '{}',
  note text,
  removed_at timestamptz not null default now(),
  -- Kept at least this long; extend it if law enforcement asks.
  keep_until timestamptz not null default now() + interval '1 year'
);

-- No policies and no privileges: invisible to the app and the API.
alter table public.preserved_photos enable row level security;
revoke all on public.preserved_photos from anon, authenticated;

-- Removes one photo from its huddle. With p_preserve (the default), it is
-- kept in preserved_photos first; pass false for a removal the law doesn't
-- ask you to keep (an adult's intimate image, a copyright notice), then
-- delete the returned file in Storage. Returns the file's Storage path.
create or replace function public.remove_reported_photo(
  p_deposit uuid, p_preserve boolean default true, p_note text default null
)
returns text
language plpgsql set search_path = public as $$
declare
  v_deposit deposits%rowtype;
  v_report_ids uuid[];
  v_photo_key text;
begin
  select * into v_deposit from deposits where id = p_deposit for update;
  if not found then raise exception 'deposit_not_found'; end if;
  select coalesce(array_agg(r.id order by r.created_at), '{}'),
         (array_agg(r.photo_key order by r.created_at desc) filter (where r.photo_key is not null))[1]
    into v_report_ids, v_photo_key
    from reports r where r.deposit_id = p_deposit;
  if p_preserve then
    insert into preserved_photos (deposit_id, huddle_id, author_id, day_key, caption, storage_path,
                                  wrapped_photo_key, photo_key, report_ids, note)
      values (v_deposit.id, v_deposit.huddle_id, v_deposit.author_id, v_deposit.day_key, v_deposit.caption,
              v_deposit.storage_path, v_deposit.wrapped_photo_key, v_photo_key, v_report_ids, p_note);
  end if;
  delete from deposits where id = p_deposit;
  return v_deposit.storage_path;
end $$;
revoke execute on function public.remove_reported_photo(uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.remove_reported_photo(uuid, boolean, text) to service_role;

-- Preserved photos past keep_until: delete each file in Storage, then its
-- row (delete from preserved_photos where id = ...).
create or replace function public.expired_preserved_photos()
returns table (id uuid, storage_path text, keep_until timestamptz)
language sql stable set search_path = public as $$
  select p.id, p.storage_path, p.keep_until from preserved_photos p
  where p.keep_until < now() order by p.keep_until;
$$;
revoke execute on function public.expired_preserved_photos() from public, anon, authenticated;
grant execute on function public.expired_preserved_photos() to service_role;

commit;
