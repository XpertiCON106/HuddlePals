-- HuddlePals — Supabase schema, RLS, and RPCs.
-- Run this whole file once in the Supabase SQL editor (Dashboard → SQL → New query).
-- Prereqs (Dashboard): Auth providers per DEPLOYMENT.md (email template
-- with {{ .Token }}, Apple client id, optional Twilio for SMS), and
-- Storage → create PRIVATE bucket named "deposits" (5 MB limit; allowed MIME
-- types image/jpeg for avatars + application/octet-stream for the
-- end-to-end encrypted huddle photos and video clips). Push notifications
-- also need the send-push edge function and two Vault secrets
-- (DEVELOPMENT.md, "Backend setup and deploys"); this file enables pg_net for
-- them. HuddlePals+ needs the verify-subscription and
-- app-store-notifications edge functions.

-- pgcrypto provides gen_random_bytes() for crypto-strength invite codes.
create extension if not exists pgcrypto;

-- ============================================================ tables

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 40),
  -- Identity color token: solid hex or "hex-hex" gradient.
  avatar_color_hex text not null default 'E5484D',
  bio text check (bio is null or char_length(bio) <= 160),
  -- Up to 3 profile photo storage paths ("avatars/<user_id>/<file>.jpg").
  photo_paths jsonb not null default '[]'::jsonb
    check (jsonb_typeof(photo_paths) = 'array' and jsonb_array_length(photo_paths) <= 3),
  created_at timestamptz not null default now()
);

create table public.huddles (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  emoji text not null default '🏔' check (char_length(emoji) between 1 and 16),
  invite_code text not null unique,
  notification_hour int not null default 19 check (notification_hour between 0 and 23),
  streak_count int not null default 0,
  last_streak_day text,
  created_at timestamptz not null default now(),
  -- True while invite_code is an old secret-less code that join_huddle
  -- accepts; false once the huddle has new-format invites, whose 6-character
  -- lookup part is all invite_code then holds (see "invites" below).
  legacy_invite boolean not null default true
);

create table public.memberships (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  huddle_id uuid not null references public.huddles (id) on delete cascade,
  role text not null default 'member' check (role in ('keeper', 'member')),
  skip_tokens_remaining int not null default 2 check (skip_tokens_remaining >= 0),
  joined_at timestamptz not null default now(),
  -- The member's local calendar day at join ("yyyy-MM-dd", like deposits'
  -- day_key). Streaks wait on a member only from the day AFTER this one.
  joined_day_key text check (joined_day_key is null or joined_day_key ~ '^\d{4}-\d{2}-\d{2}$'),
  -- When this member became the keeper (null for members). The free plan
  -- takes new members only into the 3 huddles its keeper has kept longest,
  -- so a huddle someone inherits joins the back of that queue instead of
  -- pushing their own out (huddle_join_rule).
  keeper_since timestamptz,
  unique (user_id, huddle_id)
);

create table public.deposits (
  id uuid primary key default gen_random_uuid(),
  huddle_id uuid not null references public.huddles (id) on delete cascade,
  -- Nullable + SET NULL: deposited photos are permanent and stay in the
  -- huddle's shared archive after the author deletes their account; the row
  -- survives with a null author, rendered as "Former member".
  author_id uuid references public.profiles (id) on delete set null,
  -- The Storage object holds ciphertext only (end-to-end encryption, see
  -- "end-to-end encrypted photos" below): AES-GCM under a per-photo key,
  -- which is stored here sealed with the huddle key (base64 combined box).
  -- "<huddle_id>/<uuid>.jpg", in this deposit's own huddle folder: a row
  -- can't point at another huddle's photo, and the path is safe to join onto
  -- members' local cache folders.
  storage_path text not null constraint deposits_storage_path_check check (storage_path ~* ('^' || huddle_id::text || '/[0-9a-f-]{36}\.jpg$')),
  wrapped_photo_key text not null check (wrapped_photo_key ~ '^[A-Za-z0-9+/]{80}$'),
  enc_version smallint not null default 1 check (enc_version = 1),
  caption text check (caption is null or char_length(caption) <= 80),
  day_key text not null check (day_key ~ '^\d{4}-\d{2}-\d{2}$'),
  created_at timestamptz not null default now(),
  -- A video deposit is two Storage objects sealed with the same photo key:
  -- its poster, a JPEG at storage_path as for any photo (so app builds from
  -- before videos show it as a photo), and the clip, an MP4 at video_path,
  -- the same path ending in .mp4. Posting one takes Plus (deposits_insert);
  -- it stays once Plus ends.
  media_type text not null default 'photo' constraint deposits_media_type_check check (media_type in ('photo', 'video')),
  duration_ms int constraint deposits_duration_ms_check check (duration_ms between 1 and 6100),
  video_path text,
  constraint deposits_video_check check (
    (media_type = 'video') = (video_path is not null)
    and (duration_ms is null or media_type = 'video')
    and (video_path is null or video_path = regexp_replace(storage_path, '\.jpg$', '.mp4', 'i'))
  ),
  -- Once-and-permanent: one deposit per member per huddle per day (a photo
  -- or a video, never both); a second insert fails atomically on this
  -- constraint.
  unique (huddle_id, author_id, day_key)
);

create table public.reactions (
  id uuid primary key default gen_random_uuid(),
  deposit_id uuid not null references public.deposits (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  emoji text not null check (char_length(emoji) <= 8),
  created_at timestamptz not null default now(),
  unique (deposit_id, user_id, emoji)
);

create table public.comments (
  id uuid primary key default gen_random_uuid(),
  deposit_id uuid not null references public.deposits (id) on delete cascade,
  -- SET NULL so a comment thread stays intact after its author deletes
  -- their account (rendered "Former member"), consistent with deposits.
  user_id uuid references public.profiles (id) on delete set null,
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);

create table public.skips (
  id uuid primary key default gen_random_uuid(),
  huddle_id uuid not null references public.huddles (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  day_key text not null check (day_key ~ '^\d{4}-\d{2}-\d{2}$'),
  created_at timestamptz not null default now(),
  unique (huddle_id, user_id, day_key)
);

create index deposits_huddle_day on public.deposits (huddle_id, day_key);
create index memberships_user on public.memberships (user_id);
create index reactions_deposit on public.reactions (deposit_id);
create index comments_deposit on public.comments (deposit_id);

-- ==================================================== helper functions
-- SECURITY DEFINER so policies can consult memberships without tripping
-- RLS recursion (the classic memberships-policy-reads-memberships trap).

create or replace function public.is_huddle_member(v uuid)
returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from memberships where huddle_id = v and user_id = auth.uid()); $$;

create or replace function public.is_huddle_keeper(v uuid)
returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from memberships
                  where huddle_id = v and user_id = auth.uid() and role = 'keeper'); $$;

create or replace function public.shares_huddle_with(other uuid)
returns boolean
language sql stable security definer set search_path = public as
$$ select other = auth.uid() or exists (
     select 1 from memberships m1
     join memberships m2 on m1.huddle_id = m2.huddle_id
     where m1.user_id = auth.uid() and m2.user_id = other); $$;

create or replace function public.can_see_deposit(d uuid)
returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from deposits dep
                  join memberships m on m.huddle_id = dep.huddle_id
                  where dep.id = d and m.user_id = auth.uid()); $$;

-- The caller's local "today", trusted within ±1 day of the server's date
-- (the same skew recompute_streak allows); anything else — null, malformed,
-- or out of range — falls back to the server's date.
create or replace function public.client_day_key(p_day_key text)
returns text
language plpgsql stable as $$
begin
  if p_day_key ~ '^\d{4}-\d{2}-\d{2}$'
     and p_day_key::date between now()::date - 1 and now()::date + 1 then
    return p_day_key;
  end if;
  return to_char(now(), 'YYYY-MM-DD');
exception when others then -- e.g. '2026-13-45' matches the shape but isn't a date
  return to_char(now(), 'YYYY-MM-DD');
end $$;

-- Mirrors HuddleEngine.isDayComplete: a day waits on the current members who
-- joined BEFORE it (the join day itself is free), and is complete when every
-- one of them deposited or skipped. A day that waits on nobody never counts.
-- Rows from before joined_day_key existed fall back to joined_at's date.
create or replace function public.huddle_day_complete(p_huddle uuid, p_day text)
returns boolean
language sql stable set search_path = public as $$
  with required as (
    select user_id from memberships
    where huddle_id = p_huddle
      and coalesce(joined_day_key, to_char(joined_at, 'YYYY-MM-DD')) < p_day
  ), covered as (
    select author_id as u from deposits where huddle_id = p_huddle and day_key = p_day
    union
    select user_id from skips where huddle_id = p_huddle and day_key = p_day
  )
  select exists (select 1 from required)
     and not exists (select 1 from required r where r.user_id not in (select u from covered where u is not null));
$$;

-- ============================================ plans: free and HuddlePals+
-- On the free plan an account keeps up to 3 huddles, and a huddle whose
-- keeper is on it takes up to 4 members. Plus (an App Store subscription,
-- checked by the verify-subscription and app-store-notifications edge
-- functions) keeps up to 10 huddles of up to 10 members and can post video
-- clips. When a subscription ends nobody is removed and nothing is deleted:
-- only new joins and new huddles are held back.

-- What Apple says about each subscription, written only by the edge
-- functions (service role) after checking Apple's signature. One Apple
-- subscription entitles one HuddlePals account. Goes with the account.
create table public.user_entitlements (
  -- The subscription's first transaction: the same across renewals, plan
  -- changes and resubscribing.
  original_transaction_id text primary key check (char_length(original_transaction_id) between 1 and 64),
  user_id uuid not null references auth.users (id) on delete cascade,
  product_id text not null,
  -- The newest transaction applied (each renewal is a new one).
  transaction_id text not null,
  -- App Review and TestFlight buy in the sandbox, so both count.
  environment text not null check (environment in ('Production', 'Sandbox')),
  purchased_at timestamptz,
  expires_at timestamptz not null,
  -- Billing grace period: Plus continues while Apple retries a failed renewal.
  grace_period_expires_at timestamptz,
  -- A refund or revocation ends Plus at once.
  revoked_at timestamptz,
  will_auto_renew boolean,
  -- Apple's signedDate of the newest transaction and renewal info applied.
  -- Anything Apple signed earlier (a retried or late notification, a
  -- transaction the app had cached) changes nothing.
  transaction_signed_at timestamptz not null,
  renewal_signed_at timestamptz,
  updated_at timestamptz not null default now()
);
create index user_entitlements_user on public.user_entitlements (user_id);
alter table public.user_entitlements enable row level security;
revoke all on public.user_entitlements from anon, authenticated;

-- App Store Server Notifications received, kept 90 days: which arrived and
-- when, nothing more. What they said is applied to user_entitlements.
create table public.app_store_notifications (
  notification_uuid uuid primary key,
  notification_type text not null,
  subtype text,
  original_transaction_id text,
  signed_at timestamptz not null,
  received_at timestamptz not null default now()
);
alter table public.app_store_notifications enable row level security;
revoke all on public.app_store_notifications from anon, authenticated;

-- Whether an account has Plus right now, by the server's clock. For
-- SECURITY DEFINER code only (the join and create rules): the app reads its
-- own status through my_entitlement() and policies use caller_is_premium(),
-- so nobody can look up anyone else's.
create or replace function public.is_user_premium(p_user uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from user_entitlements e
    where e.user_id = p_user
      and e.revoked_at is null
      -- greatest() skips nulls, and a grace date left from an earlier
      -- period never cuts a renewal short.
      and greatest(e.expires_at, e.grace_period_expires_at) > now()
  );
$$;
revoke execute on function public.is_user_premium(uuid) from public, anon, authenticated;
grant execute on function public.is_user_premium(uuid) to service_role;

create or replace function public.caller_is_premium()
returns boolean
language sql stable security definer set search_path = public as
$$ select is_user_premium(auth.uid()); $$;

-- Records what Apple says about one subscription. Service role only: the
-- edge functions call it once Apple's signature checks out. The account
-- that first presents a subscription keeps it while that account exists:
-- p_user is that caller (verify-subscription), or null for a notification,
-- which updates a subscription some account already holds, or gives it to
-- the account its appAccountToken names (the app sets the user's id there
-- at purchase). A token naming another account that still exists makes the
-- subscription theirs. Returns 'applied', 'stale' (Apple has since signed
-- newer information), 'in_use' (another account holds it) or 'unbound'.
create or replace function public.apply_entitlement(
  p_user uuid,
  p_original_transaction_id text,
  p_transaction_id text,
  p_product_id text,
  p_environment text,
  p_purchased_at timestamptz,
  p_expires_at timestamptz,
  p_revoked_at timestamptz,
  p_transaction_signed_at timestamptz,
  p_app_account_token uuid,
  p_grace_period_expires_at timestamptz default null,
  p_will_auto_renew boolean default null,
  p_renewal_signed_at timestamptz default null
)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_row user_entitlements%rowtype;
  v_owner uuid;
  v_applied boolean := false;
begin
  -- One subscription at a time: two accounts restoring it at once, or a
  -- notification racing the app.
  perform pg_advisory_xact_lock(hashtextextended('entitlement:' || p_original_transaction_id, 0));
  select * into v_row from user_entitlements where original_transaction_id = p_original_transaction_id;
  if found then
    if p_user is not null and p_user <> v_row.user_id then
      return 'in_use';
    end if;
    if p_transaction_signed_at > v_row.transaction_signed_at then
      update user_entitlements
         set transaction_id = p_transaction_id, product_id = p_product_id, environment = p_environment,
             purchased_at = p_purchased_at, expires_at = p_expires_at, revoked_at = p_revoked_at,
             transaction_signed_at = p_transaction_signed_at, updated_at = now()
       where original_transaction_id = p_original_transaction_id;
      v_applied := true;
    end if;
    if p_renewal_signed_at > coalesce(v_row.renewal_signed_at, '-infinity') then
      update user_entitlements
         set grace_period_expires_at = p_grace_period_expires_at, will_auto_renew = p_will_auto_renew,
             renewal_signed_at = p_renewal_signed_at, updated_at = now()
       where original_transaction_id = p_original_transaction_id;
      v_applied := true;
    end if;
    return case when v_applied then 'applied' else 'stale' end;
  end if;

  if p_user is not null and p_app_account_token is not null and p_app_account_token <> p_user
     and exists (select 1 from auth.users where id = p_app_account_token) then
    return 'in_use';
  end if;
  v_owner := coalesce(p_user, p_app_account_token);
  if v_owner is null or not exists (select 1 from auth.users where id = v_owner) then
    return 'unbound';
  end if;
  insert into user_entitlements (original_transaction_id, user_id, product_id, transaction_id, environment,
                                 purchased_at, expires_at, revoked_at, transaction_signed_at,
                                 grace_period_expires_at, will_auto_renew, renewal_signed_at)
    values (p_original_transaction_id, v_owner, p_product_id, p_transaction_id, p_environment,
            p_purchased_at, p_expires_at, p_revoked_at, p_transaction_signed_at,
            p_grace_period_expires_at, p_will_auto_renew, p_renewal_signed_at);
  return 'applied';
end $$;
revoke execute on function public.apply_entitlement(uuid, text, text, text, text, timestamptz, timestamptz,
  timestamptz, timestamptz, uuid, timestamptz, boolean, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_entitlement(uuid, text, text, text, text, timestamptz, timestamptz,
  timestamptz, timestamptz, uuid, timestamptz, boolean, timestamptz) to service_role;

-- Notes that a notification arrived (false if it already had) and forgets
-- those older than 90 days. Service role only: app-store-notifications.
create or replace function public.record_app_store_notification(
  p_uuid uuid, p_type text, p_subtype text, p_original_transaction_id text, p_signed_at timestamptz
)
returns boolean
language plpgsql set search_path = public as $$
begin
  delete from app_store_notifications where received_at < now() - interval '90 days';
  insert into app_store_notifications (notification_uuid, notification_type, subtype, original_transaction_id, signed_at)
    values (p_uuid, p_type, p_subtype, p_original_transaction_id, p_signed_at)
    on conflict (notification_uuid) do nothing;
  return found;
end $$;
revoke execute on function public.record_app_store_notification(uuid, text, text, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.record_app_store_notification(uuid, text, text, text, timestamptz) to service_role;

-- The caller's own plan, for the app: whether Plus is on and until when, the
-- server's clock (the app's "today" for the archive, whatever the phone's
-- clock says), and how many huddles they keep against which cap.
create or replace function public.my_entitlement()
returns table (
  is_premium boolean, premium_until timestamptz, server_now timestamptz,
  kept_huddles int, huddle_limit int
)
language sql stable security definer set search_path = public as $$
  select
    is_user_premium(auth.uid()),
    (select max(greatest(e.expires_at, e.grace_period_expires_at)) from user_entitlements e
      where e.user_id = auth.uid() and e.revoked_at is null),
    now(),
    (select count(*)::int from memberships m where m.user_id = auth.uid() and m.role = 'keeper'),
    case when is_user_premium(auth.uid()) then 10 else 3 end
  where auth.uid() is not null;
$$;

-- ============================================================== RLS

alter table public.profiles    enable row level security;
alter table public.huddles      enable row level security;
alter table public.memberships enable row level security;
alter table public.deposits    enable row level security;
alter table public.reactions   enable row level security;
alter table public.comments    enable row level security;
alter table public.skips       enable row level security;

-- profiles: yourself, plus anyone you share a huddle with.
create policy profiles_select on public.profiles for select
  using (shares_huddle_with(id));
create policy profiles_insert on public.profiles for insert
  with check (id = auth.uid());
create policy profiles_update on public.profiles for update
  using (id = auth.uid()) with check (id = auth.uid());

-- huddles: members read; keeper updates settings; create/join go through RPCs.
-- Column grant (below) further limits the keeper to presentational fields —
-- streak_count / invite_code are writable only by the SECURITY DEFINER RPCs.
create policy huddles_select on public.huddles for select
  using (is_huddle_member(id));
create policy huddles_update on public.huddles for update
  using (is_huddle_keeper(id)) with check (is_huddle_keeper(id));

-- M1: RLS limits UPDATE to the keeper's own huddle; this limits WHICH columns
-- they may write. streak_count / last_streak_day / invite_code are then
-- writable only by the SECURITY DEFINER RPCs (which run as the table owner
-- and bypass column grants). Stops a keeper forging the streak via PATCH.
revoke update on public.huddles from authenticated;
grant update (name, emoji, notification_hour) on public.huddles to authenticated;

-- memberships: visible to co-members; leaving deletes your own row, for a
-- member: the keeper can't leave, only delete the huddle (delete_huddle).
-- Inserts happen only inside the create_huddle / join_huddle RPCs.
create policy memberships_select on public.memberships for select
  using (is_huddle_member(huddle_id));
create policy memberships_delete on public.memberships for delete
  using (user_id = auth.uid() and role = 'member');

-- deposits: members read; you write only your own, only into your huddles,
-- and only for today-or-yesterday (the 48h backfill window, UTC-anchored —
-- generous by up to a day for non-UTC users, never blocks a legal deposit).
-- A video takes Plus at the moment it's posted.
create policy deposits_select on public.deposits for select
  using (is_huddle_member(huddle_id));
create policy deposits_insert on public.deposits for insert
  with check (
    author_id = auth.uid()
    and is_huddle_member(huddle_id)
    and day_key >= to_char(now() - interval '2 days', 'YYYY-MM-DD')
    and day_key <= to_char(now() + interval '1 day',  'YYYY-MM-DD')
    and (media_type = 'photo' or caller_is_premium())
  );
-- Once-and-permanent: deliberately NO update and NO delete policies on
-- deposits. Even a hacked client cannot edit, replace, or remove a photo
-- after it is posted.

-- reactions / comments: visible with the deposit; you manage your own.
create policy reactions_select on public.reactions for select
  using (can_see_deposit(deposit_id));
create policy reactions_insert on public.reactions for insert
  with check (user_id = auth.uid() and can_see_deposit(deposit_id));
create policy reactions_delete on public.reactions for delete
  using (user_id = auth.uid());

create policy comments_select on public.comments for select
  using (can_see_deposit(deposit_id));
create policy comments_insert on public.comments for insert
  with check (user_id = auth.uid() and can_see_deposit(deposit_id));
create policy comments_delete on public.comments for delete
  using (user_id = auth.uid());

-- skips: members read; spending goes through the spend_skip_token RPC.
create policy skips_select on public.skips for select
  using (is_huddle_member(huddle_id));

-- ============================================================== RPCs

-- Creates a huddle plus its keeper membership atomically, with a unique
-- server-generated invite code (ambiguous glyphs excluded). `p_day_key` is
-- the caller's local today, stored as the keeper's join day. An account
-- keeps up to 3 huddles on the free plan and 10 with Plus, inherited ones
-- included. Locking the caller's profile row
-- serializes their creates, so two at once can't both pass.
create or replace function public.create_huddle(p_name text, p_emoji text, p_day_key text default null)
returns setof public.huddles
language plpgsql security definer set search_path = public as $$
declare
  v_code text;
  v_huddle huddles%rowtype;
  v_kept int;
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  perform 1 from profiles where id = auth.uid() for update;
  select count(*) into v_kept from memberships where user_id = auth.uid() and role = 'keeper';
  if is_user_premium(auth.uid()) then
    if v_kept >= 10 then raise exception 'huddle_limit_reached_premium'; end if;
  elsif v_kept >= 3 then
    raise exception 'huddle_limit_reached_free';
  end if;
  loop
    v_code := '';
    -- Crypto-strength source (not the predictable `random()` PRNG); the
    -- small modulo bias over a 31-char alphabet is irrelevant for codes.
    for i in 1..6 loop
      v_code := v_code || substr(alphabet, 1 + (get_byte(extensions.gen_random_bytes(1), 0) % length(alphabet)), 1);
    end loop;
    exit when not exists (select 1 from huddles where invite_code = v_code);
  end loop;
  insert into huddles (name, emoji, invite_code) values (p_name, p_emoji, v_code)
    returning * into v_huddle;
  insert into memberships (user_id, huddle_id, role, joined_day_key, keeper_since)
    values (auth.uid(), v_huddle.id, 'keeper', client_day_key(p_day_key), now());
  return next v_huddle;
end $$;

-- Wrong invite-code guesses, per user. Codes are 6 characters from a
-- 31-character alphabet (~887M codes), few enough to enumerate with
-- unlimited tries, and a successful guess gets the huddle key shared
-- automatically. join_huddle refuses a caller with 10 misses in the last hour.
-- Only that SECURITY DEFINER function touches this table: RLS is on and there
-- are no policies, so clients can neither read nor write it.
create table public.join_attempts (
  user_id uuid not null references auth.users (id) on delete cascade,
  attempted_at timestamptz not null default now()
);
create index join_attempts_user_time on public.join_attempts (user_id, attempted_at);
alter table public.join_attempts enable row level security;

-- How many members a huddle takes, and why it refuses one more if it does.
-- The keeper's plan decides, not the members': with Plus, 10; on the free
-- plan, 4, and only in the 3 huddles they've kept longest, so a month of Plus
-- spent creating empty huddles fills just 3 of them for free afterwards.
-- No refusal says "huddle_full" and every one says
-- "blocked": app builds from before Plus show "This huddle already has 8
-- members" for any message containing "huddle_full", and "You can't join
-- this huddle." for one containing "blocked", which is true of them all.
create or replace function public.huddle_join_rule(p_huddle uuid)
returns table (member_count int, member_cap int, refusal text)
language plpgsql stable security definer set search_path = public as $$
declare
  v_keeper uuid;
begin
  select count(*)::int into member_count from memberships where huddle_id = p_huddle;
  select m.user_id into v_keeper from memberships m where m.huddle_id = p_huddle and m.role = 'keeper';
  if v_keeper is not null and is_user_premium(v_keeper) then
    member_cap := 10;
    refusal := case when member_count >= member_cap then 'join_blocked_max_members' end;
  else
    member_cap := 4;
    if v_keeper is null or p_huddle not in (
      select m.huddle_id from memberships m where m.user_id = v_keeper and m.role = 'keeper'
      order by m.keeper_since, m.huddle_id limit 3
    ) then
      refusal := 'join_blocked_invites_paused';
    elsif member_count >= member_cap then
      refusal := 'join_blocked_free_limit';
    end if;
  end if;
  return next;
end $$;
revoke execute on function public.huddle_join_rule(uuid) from public, anon, authenticated;

-- For a huddle's members: whether it takes new members right now, and if
-- not, why (huddle_join_rule's refusal), so the app can explain instead of
-- showing an invite code that would fail.
create or replace function public.huddle_join_status(p_huddle uuid)
returns table (accepting boolean, refusal text, member_count int, member_cap int)
language sql stable security definer set search_path = public as $$
  select r.refusal is null, r.refusal, r.member_count, r.member_cap
  from huddle_join_rule(p_huddle) r
  where is_huddle_member(p_huddle);
$$;

-- Validates the invite code and applies huddle_join_rule atomically: the
-- joiner's and the huddle's rows are locked before anything is counted, so
-- two people joining at once can't both take the last place, and nobody
-- passes the 25-huddle limit by joining two at once.
-- `p_day_key` is the caller's local today, stored as their join day — the
-- streak starts waiting on them the day after. An unknown code returns no
-- row (the app reads that as "no huddle for that code"): raising instead
-- would roll back the recorded miss.
-- Old secret-less codes only: once a huddle has new-format invites
-- (legacy_invite = false), its 6-character lookup is no code on its own.
create or replace function public.join_huddle(p_code text, p_day_key text default null)
returns setof public.huddles
language plpgsql security definer set search_path = public as $$
declare
  v_huddle huddles%rowtype;
  v_refusal text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from join_attempts where user_id = auth.uid() and attempted_at < now() - interval '1 hour';
  if (select count(*) from join_attempts where user_id = auth.uid()) >= 10 then
    raise exception 'too_many_attempts';
  end if;
  select * into v_huddle from huddles where upper(invite_code) = upper(trim(p_code)) and legacy_invite;
  if not found then
    insert into join_attempts (user_id) values (auth.uid());
    return;
  end if;
  if exists (select 1 from memberships where huddle_id = v_huddle.id and user_id = auth.uid()) then
    raise exception 'already_member';
  end if;
  perform 1 from profiles where id = auth.uid() for update;
  perform 1 from huddles where id = v_huddle.id for update;
  if (select count(*) from memberships where user_id = auth.uid()) >= 25 then
    raise exception 'join_blocked_membership_limit';
  end if;
  select r.refusal into v_refusal from huddle_join_rule(v_huddle.id) r;
  if v_refusal is not null then raise exception '%', v_refusal; end if;
  insert into memberships (user_id, huddle_id, joined_day_key)
    values (auth.uid(), v_huddle.id, client_day_key(p_day_key));
  return next v_huddle;
end $$;

-- A huddle always has a keeper: when the keeper leaves (or deletes their
-- account, which cascades here), the longest-standing remaining member
-- takes over, keeper from now on (keeper_since). A departing member's wrapped
-- copy of the huddle key goes with them: no key material outlives the
-- membership. Runs as the table owner, since members can't update roles or
-- delete key copies.
create or replace function public.handle_membership_removed()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from huddle_keys where huddle_id = old.huddle_id and user_id = old.user_id;
  if old.role = 'keeper'
     and not exists (select 1 from memberships where huddle_id = old.huddle_id and role = 'keeper') then
    update memberships set role = 'keeper', keeper_since = now()
      where id = (select id from memberships where huddle_id = old.huddle_id
                  order by joined_at, id limit 1);
  end if;
  return old;
end $$;

create trigger memberships_after_delete
  after delete on public.memberships
  for each row execute function public.handle_membership_removed();

-- Decrements the CALLER's token and records their skip, atomically.
-- `p_user` is accepted for signature stability but deliberately ignored:
-- the action always targets auth.uid(), so a member can never spend or
-- forge a skip on another member's behalf (was an IDOR).
create or replace function public.spend_skip_token(p_huddle uuid, p_user uuid, p_day_key text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_huddle_member(p_huddle) then raise exception 'not_a_member'; end if;
  update memberships set skip_tokens_remaining = skip_tokens_remaining - 1
    where huddle_id = p_huddle and user_id = auth.uid() and skip_tokens_remaining > 0;
  if not found then raise exception 'no_tokens_remaining'; end if;
  insert into skips (huddle_id, user_id, day_key) values (p_huddle, auth.uid(), p_day_key)
    on conflict do nothing;
end $$;

-- Server-side group streak recompute — the single source of truth, so all
-- members agree. Mirrors HuddleEngine.computeStreak: walk back from p_today
-- (the caller's local day) or yesterday; a day counts when every member it
-- waits on deposited or skipped (huddle_day_complete — members count from the
-- day after they joined); an incomplete in-progress today never breaks the
-- streak. Returns the new count.
create or replace function public.recompute_streak(p_huddle uuid, p_today text)
returns int
language plpgsql security definer set search_path = public as $$
declare
  v_cursor date;
  v_count int := 0;
  v_last date := null;
begin
  if not is_huddle_member(p_huddle) then raise exception 'not_a_member'; end if;
  -- M1: don't trust an arbitrary client day. Clamp to ±1 day of server UTC
  -- (±1 absorbs legitimate timezone skew) so a member can't pass a bogus far
  -- date to grief the streak to 0.
  if p_today::date < (now()::date - 1) or p_today::date > (now()::date + 1) then
    raise exception 'invalid_day_key';
  end if;
  v_cursor := p_today::date;

  -- If today isn't complete yet, start counting from yesterday.
  if not huddle_day_complete(p_huddle, to_char(v_cursor, 'YYYY-MM-DD')) then
    v_cursor := v_cursor - 1;
  end if;

  loop
    exit when v_count >= 36500 or not huddle_day_complete(p_huddle, to_char(v_cursor, 'YYYY-MM-DD'));
    v_count := v_count + 1;
    if v_last is null then v_last := v_cursor; end if;
    v_cursor := v_cursor - 1;
  end loop;

  update huddles set streak_count = v_count,
                    last_streak_day = case when v_last is null then null
                                           else to_char(v_last, 'YYYY-MM-DD') end
    where id = p_huddle;
  return v_count;
end $$;

-- ======================================================= storage RLS
-- One private bucket, "deposits", with two path namespaces:
--   "<huddle_id>/<file>.jpg|.mp4"     → huddle photos and video clips (ciphertext),
--                                      gated by membership; uploading a clip takes Plus
--   "avatars/<user_id>/<file>.jpg"   → profile photos: readable by the owner and
--                                      anyone who shares a huddle with them (the
--                                      same people who can read the profile row);
--                                      only the owner may write.

-- Safe uuid cast: the avatars namespace would otherwise crash the
-- huddle-membership check ('avatars'::uuid raises).
create or replace function public.try_uuid(t text)
returns uuid
language plpgsql immutable as $$
begin
  return t::uuid;
exception when others then
  return null;
end $$;

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

create policy deposits_storage_insert on storage.objects for insert
  with check (
    bucket_id = 'deposits' and (
      (
        (storage.foldername(name))[1] = 'avatars'
        and (storage.foldername(name))[2] = auth.uid()::text
      )
      or (
        try_uuid((storage.foldername(name))[1]) is not null
        and is_huddle_member(try_uuid((storage.foldername(name))[1]))
        -- Video clips: Plus only.
        and (name !~* '\.mp4$' or caller_is_premium())
      )
    )
  );

create policy deposits_storage_update on storage.objects for update
  using (
    bucket_id = 'deposits'
    and (storage.foldername(name))[1] = 'avatars'
    and (storage.foldername(name))[2] = auth.uid()::text
  );

-- Account deletion: the delete-account edge function calls this before
-- auth.admin.deleteUser. The Storage API records the uploader as each
-- object's owner, and where storage.objects.owner still references
-- auth.users that blocks deleting anyone who ever deposited a photo. Those
-- photos stay (the archive is permanent), so they're left with no owner.
-- Runs as the caller: only the service role may execute it, and it alone
-- bypasses RLS on storage.objects.
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

-- ============================================ moderation (UGC safeguards)
-- App Store guideline 1.2 requires user-generated-content apps to let users
-- report objectionable content and block other users. Monitor `reports`
-- (e.g. a dashboard query or email hook) and act within 24h.

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  -- SET NULL, not CASCADE: a report outlives its reporter's account. What
  -- the operator reports to NCMEC must be kept for a year (18 U.S.C.
  -- 2258A(h)), and photo_key is the only way to open the photo again.
  reporter_id uuid references public.profiles (id) on delete set null,
  deposit_id uuid references public.deposits (id) on delete set null,
  reported_user_id uuid references public.profiles (id) on delete set null,
  reason text check (reason is null or char_length(reason) <= 300),
  -- The reported photo's own AES key (base64), disclosed by the reporter's
  -- device so the operator can review that one photo — it opens nothing
  -- else. See tools/decrypt_reported_photo.
  photo_key text check (photo_key is null or photo_key ~ '^[A-Za-z0-9+/]{43}=$'),
  created_at timestamptz not null default now()
);

create table public.blocks (
  id uuid primary key default gen_random_uuid(),
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (blocker_id, blocked_id)
);
create index blocks_blocker on public.blocks (blocker_id);

alter table public.reports enable row level security;
alter table public.blocks  enable row level security;

-- reports: file your own; you can't read others' (only the operator can,
-- via the dashboard / service role).
create policy reports_insert on public.reports for insert
  with check (reporter_id = auth.uid());
create policy reports_select_own on public.reports for select using (reporter_id = auth.uid());

-- blocks: fully managed by the blocker.
create policy blocks_select on public.blocks for select
  using (blocker_id = auth.uid());
create policy blocks_insert on public.blocks for insert
  with check (blocker_id = auth.uid());
create policy blocks_delete on public.blocks for delete
  using (blocker_id = auth.uid());

-- Removing a reported photo while keeping it for NCMEC: what the operator
-- reports to the CyberTipline must be kept for a year (18 U.S.C. 2258A(h)),
-- and deleting a photo's row by hand loses the only pointers to its encrypted
-- file. remove_reported_photo() copies what finds and opens the photo into
-- preserved_photos, then deletes it from its huddle (reactions and comments
-- go with it); the file stays in Storage. Operator-only (SQL editor).

create table public.preserved_photos (
  id uuid primary key default gen_random_uuid(),
  -- The removed deposit. No foreign keys: the rows they'd point at are gone,
  -- or may go (a huddle, an account), and this must outlive them.
  deposit_id uuid not null,
  huddle_id uuid,
  author_id uuid,
  day_key text,
  caption text,
  -- The encrypted file, still in Storage (bucket "deposits"). For a video,
  -- its poster; the clip is video_path, the same path ending in .mp4.
  storage_path text not null,
  media_type text not null default 'photo',
  video_path text,
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

-- Removes one photo or video from its huddle. With p_preserve (the default),
-- it is kept in preserved_photos first; pass false for a removal the law
-- doesn't ask you to keep (an adult's intimate image, a copyright notice),
-- then delete the returned file in Storage, and for a video its clip too
-- (the same path ending in .mp4). Returns the file's Storage path.
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
                                  media_type, video_path, wrapped_photo_key, photo_key, report_ids, note)
      values (v_deposit.id, v_deposit.huddle_id, v_deposit.author_id, v_deposit.day_key, v_deposit.caption,
              v_deposit.storage_path, v_deposit.media_type, v_deposit.video_path, v_deposit.wrapped_photo_key,
              v_photo_key, v_report_ids, p_note);
  end if;
  delete from deposits where id = p_deposit;
  return v_deposit.storage_path;
end $$;
revoke execute on function public.remove_reported_photo(uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.remove_reported_photo(uuid, boolean, text) to service_role;

-- Preserved photos past keep_until: delete each file in Storage (for a
-- video, its video_path too), then its row (delete from preserved_photos
-- where id = ...).
create or replace function public.expired_preserved_photos()
returns table (id uuid, storage_path text, keep_until timestamptz)
language sql stable set search_path = public as $$
  select p.id, p.storage_path, p.keep_until from preserved_photos p
  where p.keep_until < now() order by p.keep_until;
$$;
revoke execute on function public.expired_preserved_photos() from public, anon, authenticated;
grant execute on function public.expired_preserved_photos() to service_role;

-- ==================================================== terms of service
-- Which version of the Terms each account agreed to, and when: the record
-- the app writes once someone who tapped Agree is signed in (TermsRecorder).
-- One row per account and version. The app never changes or removes one; it
-- goes with the account.

create table public.terms_acceptances (
  user_id uuid not null references auth.users (id) on delete cascade,
  -- TermsOfService.version: the Terms' "Last updated" date.
  version text not null check (version ~ '^\d{4}-\d{2}-\d{2}$'),
  -- When Agree was tapped, by the device's clock.
  accepted_at timestamptz not null,
  -- When the server stored the record, by its own clock.
  recorded_at timestamptz not null default now(),
  -- The app's version and build, e.g. "1.0 (10)".
  app_version text check (app_version is null or char_length(app_version) <= 40),
  primary key (user_id, version)
);

alter table public.terms_acceptances enable row level security;

-- Record your own and read them back; no updates, no deletes.
create policy terms_acceptances_select_own on public.terms_acceptances for select
  using (user_id = auth.uid());
create policy terms_acceptances_insert_own on public.terms_acceptances for insert
  with check (user_id = auth.uid());

-- recorded_at is the server's clock, never the app's.
revoke insert on public.terms_acceptances from anon, authenticated;
grant insert (user_id, version, accepted_at, app_version) on public.terms_acceptances to authenticated;

-- ============================================ end-to-end encrypted photos
-- The operator (anyone with dashboard / service-role access) must not be able
-- to view deposited photos, so Storage holds only ciphertext and every key is
-- wrapped for a member's device (Services/Live/PhotoCrypto.swift):
--   user_keys   — each user's Curve25519 public key; the private half lives
--                 only in that user's iCloud Keychain.
--   huddle_keys  — one random 256-bit huddle key per huddle, stored once per
--                 member, wrapped to that member's public key (ephemeral
--                 X25519 → HKDF-SHA256 → AES-GCM).
--   deposits.wrapped_photo_key — each photo's own key, sealed with the huddle
--                 key; the photo itself is AES-GCM under that photo key.
-- A joining member gets the huddle key from their invite code (see
-- "invites" below): the code's secret opens a sealed copy, which their app
-- then wraps for itself. Members who joined before that (or replaced their
-- identity key) are still served by an existing member's app wrapping it for
-- them (huddle_key_recipients → share_huddle_key) on foreground / huddle
-- open, but only for a public key some member has checked by comparing key
-- codes in the app (KeyCode): this table hands out public keys, so without
-- that check whoever controls it could slip in its own. Writes go through SECURITY DEFINER RPCs because the rules ("only for
-- a fellow member's CURRENT key", "never overwrite someone else's working
-- copy") can't be expressed as plain RLS when nobody may SELECT another
-- member's row.

create table public.user_keys (
  user_id uuid primary key references auth.users (id) on delete cascade,
  -- Raw 32-byte Curve25519 key-agreement public key, base64.
  public_key text not null check (public_key ~ '^[A-Za-z0-9+/]{43}=$'),
  created_at timestamptz not null default now()
);

create table public.huddle_keys (
  huddle_id uuid not null references public.huddles (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  -- AES-GCM combined box (nonce|ciphertext|tag) of the 32-byte huddle key.
  wrapped_key text not null check (wrapped_key ~ '^[A-Za-z0-9+/]{80}$'),
  -- The sender's one-time Curve25519 public key for the key agreement.
  ephemeral_public_key text not null check (ephemeral_public_key ~ '^[A-Za-z0-9+/]{43}=$'),
  -- The recipient key this copy was wrapped for. Once it differs from
  -- user_keys.public_key (the recipient lost their key and made a new one)
  -- the copy is stale and gets re-shared.
  recipient_public_key text not null check (recipient_public_key ~ '^[A-Za-z0-9+/]{43}=$'),
  wrapped_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (huddle_id, user_id)
);

alter table public.user_keys  enable row level security;
alter table public.huddle_keys enable row level security;

-- user_keys: publish / replace your own; read yours and your co-members'.
create policy user_keys_select on public.user_keys for select
  using (shares_huddle_with(user_id));
create policy user_keys_insert on public.user_keys for insert
  with check (user_id = auth.uid());
create policy user_keys_update on public.user_keys for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- huddle_keys: you read only your own copies. No direct writes at all —
-- init_huddle_key / share_huddle_key below are the only writers.
create policy huddle_keys_select_own on public.huddle_keys for select
  using (user_id = auth.uid());

-- The first key of a huddle, wrapped for the caller (normally its creator,
-- right after create_huddle). Refuses — returns false — once any current
-- member holds a copy: a huddle key is shared, never replaced, so existing
-- photos stay readable. The huddle row lock serializes concurrent attempts.
-- When nobody left holds the old key and a new one goes in, the invite
-- sealing the old key is dropped (it would hand joiners a key that opens
-- nothing new); the next member to open the huddle issues a fresh one.
create or replace function public.init_huddle_key(
  p_huddle uuid, p_wrapped_key text, p_ephemeral_public_key text, p_recipient_public_key text
)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not is_huddle_member(p_huddle) then raise exception 'not_a_member'; end if;
  if p_recipient_public_key is distinct from
     (select public_key from user_keys where user_id = auth.uid()) then
    raise exception 'stale_public_key';
  end if;
  perform 1 from huddles where id = p_huddle for update;
  if exists (select 1 from huddle_keys k
             join memberships m on m.huddle_id = k.huddle_id and m.user_id = k.user_id
             where k.huddle_id = p_huddle) then
    return false;
  end if;
  insert into huddle_keys (huddle_id, user_id, wrapped_key, ephemeral_public_key,
                          recipient_public_key, wrapped_by)
    values (p_huddle, auth.uid(), p_wrapped_key, p_ephemeral_public_key,
            p_recipient_public_key, auth.uid())
    on conflict (huddle_id, user_id) do nothing;
  if not found then
    return false;
  end if;
  delete from huddle_invite_keys where huddle_id = p_huddle;
  return true;
end $$;

-- Fellow members still waiting for the huddle key: they published a public
-- key but hold no copy, or only a stale one. Reveals nothing secret — just
-- who needs a share — and only to members of that huddle. The app shares
-- only with keys its user has checked by key code, so a row here alone
-- gets nobody the key.
create or replace function public.huddle_key_recipients(p_huddle uuid)
returns table (user_id uuid, public_key text)
language sql stable security definer set search_path = public as $$
  select m.user_id, k.public_key
  from memberships m
  join user_keys k on k.user_id = m.user_id
  left join huddle_keys vk on vk.huddle_id = m.huddle_id and vk.user_id = m.user_id
  where m.huddle_id = p_huddle
    and is_huddle_member(p_huddle)
    and m.user_id <> auth.uid()
    and (vk.user_id is null or vk.recipient_public_key <> k.public_key);
$$;

-- A member shares the huddle key with a fellow member, wrapped for that
-- member's CURRENT public key. Inserts a missing copy; replaces an existing
-- one only if the caller wrapped it or it went stale — never anyone else's
-- working copy. Self-copies come only from init_huddle_key.
create or replace function public.share_huddle_key(
  p_huddle uuid, p_user uuid, p_wrapped_key text, p_ephemeral_public_key text,
  p_recipient_public_key text
)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_user = auth.uid() then raise exception 'cannot_share_with_self'; end if;
  if not is_huddle_member(p_huddle) then raise exception 'not_a_member'; end if;
  if not exists (select 1 from memberships where huddle_id = p_huddle and user_id = p_user) then
    raise exception 'recipient_not_member';
  end if;
  if p_recipient_public_key is distinct from
     (select public_key from user_keys where user_id = p_user) then
    raise exception 'stale_public_key';
  end if;
  insert into huddle_keys (huddle_id, user_id, wrapped_key, ephemeral_public_key,
                          recipient_public_key, wrapped_by)
    values (p_huddle, p_user, p_wrapped_key, p_ephemeral_public_key,
            p_recipient_public_key, auth.uid())
    on conflict (huddle_id, user_id) do update
      set wrapped_key = excluded.wrapped_key,
          ephemeral_public_key = excluded.ephemeral_public_key,
          recipient_public_key = excluded.recipient_public_key,
          wrapped_by = excluded.wrapped_by,
          created_at = now()
      where huddle_keys.wrapped_by = auth.uid()
         or huddle_keys.recipient_public_key is distinct from excluded.recipient_public_key;
end $$;

-- ============================================================== invites
-- An invite code is a 6-character lookup part plus a 26-character secret
-- (InviteCode.swift); the server stores only the lookup, in
-- huddles.invite_code. From the secret, the inviting and the joining app
-- derive (InviteCrypto.swift) a proof, whose SHA-256 the server keeps to
-- check a code, and a wrapping key that seals the huddle key into
-- huddle_invite_keys. Redeeming a code hands the sealed key to the joiner,
-- whose app opens it and stores its own copy (save_own_huddle_key): they see
-- every photo at once, with nobody else online, and the server never holds a
-- key that opens a photo. The secret is also kept sealed with the huddle key,
-- so every member's app can show the code. One active invite per huddle.

create table public.huddle_invite_keys (
  huddle_id uuid primary key references public.huddles (id) on delete cascade,
  -- SHA-256 (hex) of the invite proof, an HKDF of the code's secret. Enough
  -- to check a code; useless for opening anything or forging one.
  proof_hash text not null check (proof_hash ~ '^[0-9a-f]{64}$'),
  -- The HKDF salt for the wrapping key (32 random bytes, base64).
  salt text not null check (salt ~ '^[A-Za-z0-9+/]{43}=$'),
  -- AES-GCM combined box of the 32-byte huddle key, under the wrapping key.
  sealed_key text not null check (sealed_key ~ '^[A-Za-z0-9+/]{80}$'),
  -- AES-GCM combined box of the code's 26-character secret, under the huddle key.
  sealed_secret text not null check (sealed_secret ~ '^[A-Za-z0-9+/]{72}$'),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.huddle_invite_keys enable row level security;
-- No policies, and no table privileges either: only the SECURITY DEFINER
-- functions below touch it.
revoke all on public.huddle_invite_keys from anon, authenticated;

-- The stored form of an invite proof (base64 of 32 bytes); null if malformed.
create or replace function public.invite_proof_hash(p_proof text)
returns text
language sql immutable set search_path = public as $$
  select case when p_proof ~ '^[A-Za-z0-9+/]{43}=$'
              then encode(sha256(decode(p_proof, 'base64')), 'hex') end;
$$;

-- Whether the caller holds a working copy of the huddle key (one wrapped for
-- their current public key): only they can seal it into an invite.
create or replace function public.holds_huddle_key(p_huddle uuid)
returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from huddle_keys k
                  join user_keys u on u.user_id = k.user_id
                  where k.huddle_id = p_huddle and k.user_id = auth.uid()
                    and k.recipient_public_key = u.public_key); $$;

-- Joins with a new-format invite. The caller proves they hold the code (the
-- proof's hash must match) under the same 10-misses-an-hour limit as
-- join_huddle; then the same limits and locks, plus: nobody in the huddle
-- has blocked them. Returns the sealed huddle key for the caller's app to
-- open with the code's secret. A wrong code returns no row, so the miss is
-- recorded.
create or replace function public.redeem_huddle_invite(p_lookup text, p_proof text, p_day_key text default null)
returns table (joined_huddle_id uuid, invite_salt text, invite_sealed_key text)
language plpgsql security definer set search_path = public as $$
declare
  v_invite huddle_invite_keys%rowtype;
  v_refusal text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from join_attempts where user_id = auth.uid() and attempted_at < now() - interval '1 hour';
  if (select count(*) from join_attempts where user_id = auth.uid()) >= 10 then
    raise exception 'too_many_attempts';
  end if;
  select k.* into v_invite
    from huddles h join huddle_invite_keys k on k.huddle_id = h.id
   where upper(h.invite_code) = upper(trim(p_lookup))
     and k.proof_hash = invite_proof_hash(p_proof);
  if not found then
    insert into join_attempts (user_id) values (auth.uid());
    return;
  end if;
  if exists (select 1 from memberships m where m.huddle_id = v_invite.huddle_id and m.user_id = auth.uid()) then
    raise exception 'already_member';
  end if;
  perform 1 from profiles where id = auth.uid() for update;
  perform 1 from huddles where id = v_invite.huddle_id for update;
  if (select count(*) from memberships m where m.user_id = auth.uid()) >= 25 then
    raise exception 'join_blocked_membership_limit';
  end if;
  select r.refusal into v_refusal from huddle_join_rule(v_invite.huddle_id) r;
  if v_refusal is not null then raise exception '%', v_refusal; end if;
  if exists (select 1 from blocks b
             join memberships m on m.user_id = b.blocker_id and m.huddle_id = v_invite.huddle_id
             where b.blocked_id = auth.uid()) then
    raise exception 'blocked';
  end if;
  insert into memberships (user_id, huddle_id, joined_day_key)
    values (auth.uid(), v_invite.huddle_id, client_day_key(p_day_key));
  joined_huddle_id := v_invite.huddle_id;
  invite_salt := v_invite.salt;
  invite_sealed_key := v_invite.sealed_key;
  return next;
end $$;

-- What members' apps need to show the invite: the lookup part, the secret
-- sealed with the huddle key (null when there's no active invite), and
-- whether the huddle still runs on an old code. Members only.
create or replace function public.huddle_invite(p_huddle uuid)
returns table (lookup text, legacy boolean, sealed_secret text)
language sql stable security definer set search_path = public as $$
  select h.invite_code, h.legacy_invite, k.sealed_secret
  from huddles h left join huddle_invite_keys k on k.huddle_id = h.id
  where h.id = p_huddle and is_huddle_member(p_huddle);
$$;

-- Issues the huddle's first new-format invite: on creation, or when a
-- member opens a huddle still on an old code (or whose invite was dropped
-- because its key was replaced). Any member holding the key may; returns
-- false if another member's app got there first. Retires the old code.
create or replace function public.create_huddle_invite(
  p_huddle uuid, p_lookup text, p_proof text, p_salt text, p_sealed_key text, p_sealed_secret text
)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not is_huddle_member(p_huddle) then raise exception 'not_a_member'; end if;
  if not holds_huddle_key(p_huddle) then raise exception 'no_huddle_key'; end if;
  if coalesce(p_lookup, '') !~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$' or invite_proof_hash(p_proof) is null then
    raise exception 'invalid_invite';
  end if;
  perform 1 from huddles where id = p_huddle for update;
  if exists (select 1 from huddle_invite_keys where huddle_id = p_huddle) then
    return false;
  end if;
  begin
    update huddles set invite_code = p_lookup, legacy_invite = false where id = p_huddle;
  exception when unique_violation then
    raise exception 'invite_code_taken';
  end;
  insert into huddle_invite_keys (huddle_id, proof_hash, salt, sealed_key, sealed_secret, created_by)
    values (p_huddle, invite_proof_hash(p_proof), p_salt, p_sealed_key, p_sealed_secret, auth.uid());
  return true;
end $$;

-- The keeper replaces the invite: the old code, and its sealed copy of the
-- huddle key, stop working at once.
create or replace function public.reset_huddle_invite(
  p_huddle uuid, p_lookup text, p_proof text, p_salt text, p_sealed_key text, p_sealed_secret text
)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not is_huddle_keeper(p_huddle) then raise exception 'not_keeper'; end if;
  if not holds_huddle_key(p_huddle) then raise exception 'no_huddle_key'; end if;
  if coalesce(p_lookup, '') !~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$' or invite_proof_hash(p_proof) is null then
    raise exception 'invalid_invite';
  end if;
  perform 1 from huddles where id = p_huddle for update;
  delete from huddle_invite_keys where huddle_id = p_huddle;
  begin
    update huddles set invite_code = p_lookup, legacy_invite = false where id = p_huddle;
  exception when unique_violation then
    raise exception 'invite_code_taken';
  end;
  insert into huddle_invite_keys (huddle_id, proof_hash, salt, sealed_key, sealed_secret, created_by)
    values (p_huddle, invite_proof_hash(p_proof), p_salt, p_sealed_key, p_sealed_secret, auth.uid());
end $$;

-- A member who just joined with an invite stores their own copy of the
-- huddle key, wrapped for their current public key, so their access never
-- depends on the invite again. Inserts a missing copy or replaces a stale
-- one; never a working copy.
create or replace function public.save_own_huddle_key(
  p_huddle uuid, p_wrapped_key text, p_ephemeral_public_key text, p_recipient_public_key text
)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not is_huddle_member(p_huddle) then raise exception 'not_a_member'; end if;
  if p_recipient_public_key is distinct from
     (select public_key from user_keys where user_id = auth.uid()) then
    raise exception 'stale_public_key';
  end if;
  insert into huddle_keys (huddle_id, user_id, wrapped_key, ephemeral_public_key,
                          recipient_public_key, wrapped_by)
    values (p_huddle, auth.uid(), p_wrapped_key, p_ephemeral_public_key,
            p_recipient_public_key, auth.uid())
    on conflict (huddle_id, user_id) do update
      set wrapped_key = excluded.wrapped_key,
          ephemeral_public_key = excluded.ephemeral_public_key,
          recipient_public_key = excluded.recipient_public_key,
          wrapped_by = excluded.wrapped_by,
          created_at = now()
      where huddle_keys.recipient_public_key is distinct from excluded.recipient_public_key;
  return found;
end $$;

-- ================================================== push notifications
-- Devices register their APNs token in device_tokens; inserts into deposits,
-- comments, reactions and memberships ask the send-push edge function
-- (through pg_net) to notify the right people: every other member for a new
-- photo or a new member, the photo's owner for a comment or a reaction. Never
-- the person who did it, and never across a block. The triggers read two
-- Vault secrets and do nothing until both exist (DEVELOPMENT.md, "Backend
-- setup and deploys"): push_function_url and push_webhook_secret.

-- pg_net sends the triggers' requests after the transaction commits. Guarded
-- so databases without it (the local test database) still load.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net with schema extensions;
  end if;
end $$;

create table public.device_tokens (
  user_id uuid not null references auth.users (id) on delete cascade,
  -- The APNs device token, hex. Apple doesn't promise a length.
  token text not null check (token ~ '^[0-9a-f]{64,200}$'),
  -- Which APNs host the token belongs to: development builds get sandbox
  -- tokens, TestFlight and App Store builds production ones.
  environment text not null check (environment in ('sandbox', 'production')),
  updated_at timestamptz not null default now(),
  primary key (user_id, token)
);
create index device_tokens_token on public.device_tokens (token);
alter table public.device_tokens enable row level security;

-- Each user manages their own rows only.
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

create trigger device_tokens_touch
  before insert or update on public.device_tokens
  for each row execute function public.touch_updated_at();

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

-- Who to notify about one event, with what the notification says: the
-- huddle's name and emoji, the actor's display name, and for a reaction its
-- emoji (none of it end-to-end encrypted; captions and comment text are never
-- sent). Recipients are current members (for a deleted huddle, everyone who
-- was in it), never the actor, never anyone who has blocked the actor or whom
-- the actor has blocked. Each device token counts only for the account that
-- registered it last. Service role only: the send-push function calls it.
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

-- What a notification's deposit is, 'photo' or 'video', so it can say which
-- (null for a join). Service role only: send-push calls it.
create or replace function public.push_media_type(p_kind text, p_id uuid)
returns text
language sql stable set search_path = public as $$
  select d.media_type from deposits d where p_kind = 'deposit' and d.id = p_id
  union all
  select d.media_type from comments c join deposits d on d.id = c.deposit_id
   where p_kind = 'comment' and c.id = p_id
  union all
  select d.media_type from reactions r join deposits d on d.id = r.deposit_id
   where p_kind = 'reaction' and r.id = p_id
  limit 1;
$$;
revoke execute on function public.push_media_type(text, uuid) from public, anon, authenticated;
grant execute on function public.push_media_type(text, uuid) to service_role;

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

-- AFTER INSERT on the four tables: asks send-push to notify about the new
-- row (queue_push). Never gets in the way of the insert itself.
create or replace function public.notify_push()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform queue_push(tg_argv[0], new.id);
  return new;
end $$;
revoke execute on function public.notify_push() from public, anon, authenticated;

create trigger deposits_push
  after insert on public.deposits
  for each row execute function public.notify_push('deposit');

create trigger comments_push
  after insert on public.comments
  for each row execute function public.notify_push('comment');

create trigger reactions_push
  after insert on public.reactions
  for each row execute function public.notify_push('reaction');

create trigger memberships_push
  after insert on public.memberships
  for each row execute function public.notify_push('join');

-- ===================================================== deleting a huddle
-- A keeper deletes their huddle: everyone is removed, and every photo,
-- video, caption, comment, reaction, skip, key and invite goes with it (the
-- delete-huddle edge function deletes its files). A deposit someone reported
-- is kept first in preserved_photos, so the operator can still review it and
-- keep what NCMEC needs; everyone else who was in it is told.
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

-- ====================================== last member deletes their account
-- When someone deletes their account, every huddle they are the only member
-- of goes with them (the delete-account edge function deletes its files).
-- A deposit someone reported is kept first in preserved_photos, so the
-- operator can still review it and keep what NCMEC needs; its files stay
-- in Storage. Nobody else was in it, so there is no notification. A huddle
-- that still has another member is left alone.
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

-- ============================================================ birthdays
-- Asked when a profile is made (and once of accounts from before), to keep
-- HuddlePals to people 13 and older (Terms 2.1). Only the account's owner
-- reads or changes theirs, and it goes with the profile. The age rule
-- allows a day for time zones: the app checks the age on the person's own
-- calendar.
create table public.profile_birthdates (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  birth_date date not null check (birth_date >= date '1900-01-01')
);
alter table public.profile_birthdates enable row level security;
revoke all on public.profile_birthdates from anon, authenticated;
grant select, insert, update on public.profile_birthdates to authenticated;
create policy profile_birthdates_select on public.profile_birthdates for select
  using (user_id = auth.uid());
create policy profile_birthdates_insert on public.profile_birthdates for insert
  with check (user_id = auth.uid() and birth_date <= (current_date - interval '13 years' + interval '1 day')::date);
create policy profile_birthdates_update on public.profile_birthdates for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and birth_date <= (current_date - interval '13 years' + interval '1 day')::date);

-- Live updates: deposits, comments and reactions go out over Supabase
-- Realtime (Postgres changes); Realtime checks every row against the
-- table's RLS with the listener's own token. Only where the
-- supabase_realtime publication exists (every Supabase project has it).
do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['deposits', 'comments', 'reactions'] loop
      if not exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
      ) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

-- ============================================ already ran an older schema?
-- This file only builds a fresh database. To start over on one that ran an
-- earlier copy, run supabase/scripts/reset_database.sql (destructive), empty
-- the "deposits" bucket, then run this file again.
