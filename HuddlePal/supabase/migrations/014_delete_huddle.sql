-- A keeper can delete their huddle. Everyone is removed, and every photo,
-- video, caption, comment, reaction, skip, key and invite goes with it; the
-- delete-huddle edge function then deletes the huddle's files from Storage.
-- A deposit someone reported is kept first in preserved_photos, as
-- remove_reported_photo() keeps one, so the operator can still review it and
-- keep what NCMEC needs (18 U.S.C. 2258A(h)); its files stay in Storage.
-- Everyone else who was in the huddle is told (send-push, kind
-- 'huddle_deleted'). Safe to re-run.

begin;

-- What a deleted huddle leaves for its notification: by the time send-push
-- runs, its rows are gone. Kept a week, then cleared by the next deletion.
create table if not exists public.huddle_deletions (
  id uuid primary key default gen_random_uuid(),
  huddle_id uuid not null,
  huddle_name text not null,
  huddle_emoji text,
  actor_id uuid references public.profiles (id) on delete set null,
  -- Everyone else who was in it.
  member_ids uuid[] not null default '{}',
  deleted_at timestamptz not null default now()
);
alter table public.huddle_deletions enable row level security;
revoke all on public.huddle_deletions from anon, authenticated;

-- Asks the send-push function to notify about one event (its kind and id),
-- once the transaction commits. Does nothing without the Vault secrets, and
-- never fails what called it.
create or replace function public.queue_push(p_kind text, p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_url text;
  v_secret text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'push_function_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_webhook_secret';
  if v_url is null or v_secret is null then
    return;
  end if;
  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('kind', p_kind, 'id', p_id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    timeout_milliseconds := 5000
  );
exception when others then
  return;
end $$;
revoke execute on function public.queue_push(text, uuid) from public, anon, authenticated;

create or replace function public.notify_push()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform queue_push(tg_argv[0], new.id);
  return new;
end $$;
revoke execute on function public.notify_push() from public, anon, authenticated;

-- push_targets learns 'huddle_deleted': everyone who was in the huddle, from
-- the record its deletion left.
create or replace function public.push_targets(p_kind text, p_id uuid)
returns table (
  user_id uuid, token text, environment text,
  huddle_id uuid, huddle_name text, huddle_emoji text, actor_name text, detail text
)
language sql stable set search_path = public as $$
  with event as (
    select d.huddle_id, d.author_id as actor_id, null::uuid as owner_id, null::text as detail
      from deposits d where p_kind = 'deposit' and d.id = p_id
    union all
    select d.huddle_id, c.user_id, d.author_id, null
      from comments c join deposits d on d.id = c.deposit_id
     where p_kind = 'comment' and c.id = p_id
    union all
    select d.huddle_id, r.user_id, d.author_id, r.emoji
      from reactions r join deposits d on d.id = r.deposit_id
     where p_kind = 'reaction' and r.id = p_id
    union all
    select m.huddle_id, m.user_id, null, null
      from memberships m where p_kind = 'join' and m.id = p_id
  ), recipients as (
    select m.user_id, e.huddle_id, e.actor_id, e.detail
      from event e
      join memberships m on m.huddle_id = e.huddle_id
     where e.actor_id is not null
       and m.user_id <> e.actor_id
       and (p_kind in ('deposit', 'join') or m.user_id = e.owner_id)
    union all
    select u.member_id, x.huddle_id, x.actor_id, null
      from huddle_deletions x cross join unnest(x.member_ids) as u (member_id)
     where p_kind = 'huddle_deleted' and x.id = p_id
       and x.actor_id is not null
       and u.member_id <> x.actor_id
  ), allowed as (
    select r.* from recipients r
     where not exists (
       select 1 from blocks b
        where (b.blocker_id = r.user_id and b.blocked_id = r.actor_id)
           or (b.blocker_id = r.actor_id and b.blocked_id = r.user_id)
     )
  )
  select t.user_id, t.token, t.environment, r.huddle_id,
         coalesce(h.name, x.huddle_name), coalesce(h.emoji, x.huddle_emoji), p.display_name, r.detail
    from allowed r
    join device_tokens t on t.user_id = r.user_id
    left join huddles h on h.id = r.huddle_id
    left join huddle_deletions x on p_kind = 'huddle_deleted' and x.id = p_id
    left join profiles p on p.id = r.actor_id
   where (h.id is not null or x.id is not null)
     and not exists (
       select 1 from device_tokens newer
        where newer.token = t.token and newer.user_id <> t.user_id
          and (newer.updated_at, newer.user_id) > (t.updated_at, t.user_id)
     );
$$;
revoke execute on function public.push_targets(text, uuid) from public, anon, authenticated;
grant execute on function public.push_targets(text, uuid) to service_role;

-- Deletes a huddle for its keeper. Returns the Storage files to keep (a
-- reported deposit's poster and clip); the delete-huddle function deletes
-- the rest of the huddle's folder. Service role only: the function checks
-- who is calling.
create or replace function public.delete_huddle(p_huddle uuid, p_user uuid)
returns text[]
language plpgsql set search_path = public as $$
declare
  v_huddle huddles%rowtype;
  v_deletion uuid;
  v_kept text[];
begin
  select * into v_huddle from huddles where id = p_huddle for update;
  if not found then raise exception 'huddle_not_found'; end if;
  if not exists (
    select 1 from memberships where huddle_id = p_huddle and user_id = p_user and role = 'keeper'
  ) then
    raise exception 'not_keeper';
  end if;
  insert into preserved_photos (deposit_id, huddle_id, author_id, day_key, caption, storage_path,
                                media_type, video_path, wrapped_photo_key, photo_key, report_ids, note)
    select d.id, d.huddle_id, d.author_id, d.day_key, d.caption, d.storage_path,
           d.media_type, d.video_path, d.wrapped_photo_key,
           (array_agg(r.photo_key order by r.created_at desc) filter (where r.photo_key is not null))[1],
           array_agg(r.id order by r.created_at), 'Kept when its keeper deleted the huddle'
      from deposits d join reports r on r.deposit_id = d.id
     where d.huddle_id = p_huddle
     group by d.id;
  delete from huddle_deletions where deleted_at < now() - interval '7 days';
  insert into huddle_deletions (huddle_id, huddle_name, huddle_emoji, actor_id, member_ids)
    select p_huddle, v_huddle.name, v_huddle.emoji, p_user, coalesce(array_agg(m.user_id), '{}')
      from memberships m where m.huddle_id = p_huddle and m.user_id <> p_user
    returning id into v_deletion;
  delete from huddles where id = p_huddle;
  perform queue_push('huddle_deleted', v_deletion);
  select coalesce(array_agg(k.path), '{}') into v_kept from (
    select storage_path as path from preserved_photos where huddle_id = p_huddle
    union
    select video_path from preserved_photos where huddle_id = p_huddle and video_path is not null
  ) k;
  return v_kept;
end $$;
revoke execute on function public.delete_huddle(uuid, uuid) from public, anon, authenticated;
grant execute on function public.delete_huddle(uuid, uuid) to service_role;

commit;
