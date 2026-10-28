-- When the last member of a huddle deletes their account, that huddle goes
-- with them: every photo, video, caption, comment, reaction, skip, key and
-- invite. The delete-account edge function then deletes the huddle's files
-- from Storage. A deposit someone reported is kept first in preserved_photos,
-- as delete_huddle keeps one, so the operator can still review it and keep
-- what NCMEC needs (18 U.S.C. 2258A(h)); its files stay in Storage. Nobody
-- else was in the huddle, so there is no notification. A huddle that still
-- has another member is left alone: its posts stay, and the author becomes
-- null with the account. Safe to re-run.

begin;

-- Deletes every huddle in which p_user is the only member. Returns a JSON
-- array of {"huddle_id", "kept_paths"} for the huddles it deleted: the
-- Storage paths to keep (a reported deposit's poster and clip). The
-- delete-account function deletes the rest of each huddle's folder.
-- Service role only.
create or replace function public.delete_sole_huddles(p_user uuid)
returns jsonb
language plpgsql set search_path = public as $$
declare
  v_huddle uuid;
  v_kept text[];
  v_deleted jsonb := '[]'::jsonb;
begin
  for v_huddle in
    select h.id
      from huddles h
     where exists (
       select 1 from memberships m
        where m.huddle_id = h.id and m.user_id = p_user
     )
       and not exists (
         select 1 from memberships o
          where o.huddle_id = h.id and o.user_id <> p_user
       )
     order by h.id
     for update
  loop
    insert into preserved_photos (deposit_id, huddle_id, author_id, day_key, caption, storage_path,
                                  media_type, video_path, wrapped_photo_key, photo_key, report_ids, note)
      select d.id, d.huddle_id, d.author_id, d.day_key, d.caption, d.storage_path,
             d.media_type, d.video_path, d.wrapped_photo_key,
             (array_agg(r.photo_key order by r.created_at desc) filter (where r.photo_key is not null))[1],
             array_agg(r.id order by r.created_at), 'Kept when its last member deleted their account'
        from deposits d join reports r on r.deposit_id = d.id
       where d.huddle_id = v_huddle
       group by d.id;
    delete from huddles where id = v_huddle;
    select coalesce(array_agg(k.path), '{}') into v_kept from (
      select storage_path as path from preserved_photos where huddle_id = v_huddle
      union
      select video_path from preserved_photos where huddle_id = v_huddle and video_path is not null
    ) k;
    v_deleted := v_deleted || jsonb_build_array(jsonb_build_object(
      'huddle_id', v_huddle,
      'kept_paths', to_jsonb(v_kept)
    ));
  end loop;
  return v_deleted;
end $$;
revoke execute on function public.delete_sole_huddles(uuid) from public, anon, authenticated;
grant execute on function public.delete_sole_huddles(uuid) to service_role;

commit;
