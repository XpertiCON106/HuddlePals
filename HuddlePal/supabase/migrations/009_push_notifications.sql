-- Push notifications (APNs). Devices register their APNs token in
-- device_tokens; inserts into deposits, comments, reactions and memberships
-- ask the send-push edge function (through pg_net) to notify the right
-- people: every other member for a new photo or a new member, the photo's
-- owner for a comment or a reaction. Never the person who did it, and never
-- across a block. Safe to re-run.
--
-- The triggers read two Vault secrets and do nothing until both exist
-- (DEVELOPMENT.md, "Backend setup and deploys"):
--   push_function_url    https://<project-ref>.supabase.co/functions/v1/send-push
--   push_webhook_secret  the same value as the function's PUSH_WEBHOOK_SECRET

begin;

-- pg_net sends the triggers' requests after the transaction commits. Guarded
-- so databases without it (the local test database) still load.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net with schema extensions;
  end if;
end $$;

create table if not exists public.device_tokens (
  user_id uuid not null references auth.users (id) on delete cascade,
  -- The APNs device token, hex. Apple doesn't promise a length.
  token text not null check (token ~ '^[0-9a-f]{64,200}$'),
  -- Which APNs host the token belongs to: development builds get sandbox
  -- tokens, TestFlight and App Store builds production ones.
  environment text not null check (environment in ('sandbox', 'production')),
  updated_at timestamptz not null default now(),
  primary key (user_id, token)
);
create index if not exists device_tokens_token on public.device_tokens (token);
alter table public.device_tokens enable row level security;

-- Each user manages their own rows only.
drop policy if exists device_tokens_select_own on public.device_tokens;
drop policy if exists device_tokens_insert_own on public.device_tokens;
drop policy if exists device_tokens_update_own on public.device_tokens;
drop policy if exists device_tokens_delete_own on public.device_tokens;
create policy device_tokens_select_own on public.device_tokens for select
  using (user_id = auth.uid());
create policy device_tokens_insert_own on public.device_tokens for insert
  with check (user_id = auth.uid());
create policy device_tokens_update_own on public.device_tokens for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy device_tokens_delete_own on public.device_tokens for delete
  using (user_id = auth.uid());

-- Re-registering refreshes updated_at: when one device's token is on file
-- for two accounts (an earlier sign-out that couldn't reach the server),
-- only the account that registered it last is notified.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists device_tokens_touch on public.device_tokens;
create trigger device_tokens_touch
  before insert or update on public.device_tokens
  for each row execute function public.touch_updated_at();

-- Who to notify about one event, with what the notification says: the
-- huddle's name and emoji, the actor's display name, and for a reaction its
-- emoji (none of it end-to-end encrypted; captions and comment text are never
-- sent). Recipients are current members, never the actor, never anyone who
-- has blocked the actor or whom the actor has blocked. Each device token
-- counts only for the account that registered it last. Service role only:
-- the send-push function calls it.
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
       and not exists (
         select 1 from blocks b
          where (b.blocker_id = m.user_id and b.blocked_id = e.actor_id)
             or (b.blocker_id = e.actor_id and b.blocked_id = m.user_id)
       )
  )
  select t.user_id, t.token, t.environment, r.huddle_id, h.name, h.emoji, p.display_name, r.detail
    from recipients r
    join device_tokens t on t.user_id = r.user_id
    join huddles h on h.id = r.huddle_id
    left join profiles p on p.id = r.actor_id
   where not exists (
     select 1 from device_tokens newer
      where newer.token = t.token and newer.user_id <> t.user_id
        and (newer.updated_at, newer.user_id) > (t.updated_at, t.user_id)
   );
$$;
revoke execute on function public.push_targets(text, uuid) from public, anon, authenticated;
grant execute on function public.push_targets(text, uuid) to service_role;

-- AFTER INSERT on the four tables: queues a POST to send-push with the kind
-- of event and the new row's id. pg_net sends it only once the insert
-- commits. Never gets in the way of the insert itself: without the Vault
-- secrets it does nothing, and any failure is swallowed.
create or replace function public.notify_push()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_url text;
  v_secret text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'push_function_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_webhook_secret';
  if v_url is null or v_secret is null then
    return new;
  end if;
  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('kind', tg_argv[0], 'id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    timeout_milliseconds := 5000
  );
  return new;
exception when others then
  return new;
end $$;
revoke execute on function public.notify_push() from public, anon, authenticated;

drop trigger if exists deposits_push on public.deposits;
create trigger deposits_push
  after insert on public.deposits
  for each row execute function public.notify_push('deposit');

drop trigger if exists comments_push on public.comments;
create trigger comments_push
  after insert on public.comments
  for each row execute function public.notify_push('comment');

drop trigger if exists reactions_push on public.reactions;
create trigger reactions_push
  after insert on public.reactions
  for each row execute function public.notify_push('reaction');

drop trigger if exists memberships_push on public.memberships;
create trigger memberships_push
  after insert on public.memberships
  for each row execute function public.notify_push('join');

commit;
