-- HuddlePals — Supabase schema, RLS, and RPCs.
-- Run this whole file once in the Supabase SQL editor (Dashboard → SQL → New query).
-- Prereqs (Dashboard): Auth providers per DEPLOYMENT.md (email template
-- with {{ .Token }}, Apple client id, optional Twilio for SMS), and
-- Storage → create PRIVATE bucket named "deposits" (5 MB limit; allowed MIME
-- types image/jpeg for avatars + application/octet-stream for the
-- end-to-end encrypted huddle photos).

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
  photo_paths jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);

create table public.huddles (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  emoji text not null default '🏔',
  invite_code text not null unique,
  notification_hour int not null default 19 check (notification_hour between 0 and 23),
  streak_count int not null default 0,
  last_streak_day text,
  created_at timestamptz not null default now()
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
  storage_path text not null,
  wrapped_photo_key text not null check (wrapped_photo_key ~ '^[A-Za-z0-9+/]{80}$'),
  enc_version smallint not null default 1 check (enc_version = 1),
  caption text check (caption is null or char_length(caption) <= 80),
  day_key text not null check (day_key ~ '^\d{4}-\d{2}-\d{2}$'),
  created_at timestamptz not null default now(),
  -- Once-and-permanent: one deposit per member per huddle per day; a second
  -- insert fails atomically on this constraint.
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

-- memberships: visible to co-members; leaving deletes your own row.
-- Inserts happen only inside the create_huddle / join_huddle RPCs.
create policy memberships_select on public.memberships for select
  using (is_huddle_member(huddle_id));
create policy memberships_delete on public.memberships for delete
  using (user_id = auth.uid());

-- deposits: members read; you write only your own, only into your huddles,
-- and only for today-or-yesterday (the 48h backfill window, UTC-anchored —
-- generous by up to a day for non-UTC users, never blocks a legal deposit).
create policy deposits_select on public.deposits for select
  using (is_huddle_member(huddle_id));
create policy deposits_insert on public.deposits for insert
  with check (
    author_id = auth.uid()
    and is_huddle_member(huddle_id)
    and day_key >= to_char(now() - interval '2 days', 'YYYY-MM-DD')
    and day_key <= to_char(now() + interval '1 day',  'YYYY-MM-DD')
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
-- the caller's local today, stored as the keeper's join day.
create or replace function public.create_huddle(p_name text, p_emoji text, p_day_key text default null)
returns setof public.huddles
language plpgsql security definer set search_path = public as $$
declare
  v_code text;
  v_huddle huddles%rowtype;
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
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
  insert into memberships (user_id, huddle_id, role, joined_day_key)
    values (auth.uid(), v_huddle.id, 'keeper', client_day_key(p_day_key));
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

-- Validates the invite code and enforces the 8-member cap atomically.
-- `p_day_key` is the caller's local today, stored as their join day — the
-- streak starts waiting on them the day after. An unknown code returns no
-- row (the app reads that as "no huddle for that code"): raising instead
-- would roll back the recorded miss.
create or replace function public.join_huddle(p_code text, p_day_key text default null)
returns setof public.huddles
language plpgsql security definer set search_path = public as $$
declare
  v_huddle huddles%rowtype;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from join_attempts where user_id = auth.uid() and attempted_at < now() - interval '1 hour';
  if (select count(*) from join_attempts where user_id = auth.uid()) >= 10 then
    raise exception 'too_many_attempts';
  end if;
  select * into v_huddle from huddles where upper(invite_code) = upper(trim(p_code));
  if not found then
    insert into join_attempts (user_id) values (auth.uid());
    return;
  end if;
  if exists (select 1 from memberships where huddle_id = v_huddle.id and user_id = auth.uid()) then
    raise exception 'already_member';
  end if;
  if (select count(*) from memberships where huddle_id = v_huddle.id) >= 8 then
    raise exception 'huddle_full';
  end if;
  insert into memberships (user_id, huddle_id, joined_day_key)
    values (auth.uid(), v_huddle.id, client_day_key(p_day_key));
  return next v_huddle;
end $$;

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
--   "<huddle_id>/<file>.jpg"          → huddle photos (ciphertext), gated by membership
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
      )
    )
  );

create policy deposits_storage_update on storage.objects for update
  using (
    bucket_id = 'deposits'
    and (storage.foldername(name))[1] = 'avatars'
    and (storage.foldername(name))[2] = auth.uid()::text
  );

-- ============================================ moderation (UGC safeguards)
-- App Store guideline 1.2 requires user-generated-content apps to let users
-- report objectionable content and block other users. Monitor `reports`
-- (e.g. a dashboard query or email hook) and act within 24h.

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles (id) on delete cascade,
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
-- A joining member can't get the huddle key from the server alone: an
-- existing member's app wraps it for them (huddle_key_recipients →
-- share_huddle_key) on foreground / huddle open. Writes go through SECURITY
-- DEFINER RPCs because the rules ("only for a fellow member's CURRENT key",
-- "never overwrite someone else's working copy") can't be expressed as plain
-- RLS when nobody may SELECT another member's row.

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
  return found;
end $$;

-- Fellow members still waiting for the huddle key: they published a public
-- key but hold no copy, or only a stale one. Reveals nothing secret — just
-- who needs a share — and only to members of that huddle.
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

-- ============================================ already ran an older schema?
-- This file only builds a fresh database. To start over on one that ran an
-- earlier copy, run supabase/scripts/reset_database.sql (destructive), empty
-- the "deposits" bucket, then run this file again.
