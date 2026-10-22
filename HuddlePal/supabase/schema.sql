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
-- Old secret-less codes only: once a huddle has new-format invites
-- (legacy_invite = false), its 6-character lookup is no code on its own.
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
  select * into v_huddle from huddles where upper(invite_code) = upper(trim(p_code)) and legacy_invite;
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

-- A huddle always has a keeper: when the keeper leaves (or deletes their
-- account, which cascades here), the longest-standing remaining member
-- takes over. A departing member's wrapped copy of the huddle key goes with
-- them: no key material outlives the membership. Runs as the table owner,
-- since members can't update roles or delete key copies.
create or replace function public.handle_membership_removed()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from huddle_keys where huddle_id = old.huddle_id and user_id = old.user_id;
  if old.role = 'keeper'
     and not exists (select 1 from memberships where huddle_id = old.huddle_id and role = 'keeper') then
    update memberships set role = 'keeper'
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
-- A joining member gets the huddle key from their invite code (see
-- "invites" below): the code's secret opens a sealed copy, which their app
-- then wraps for itself. Members who joined before that (or replaced their
-- identity key) are still served by an existing member's app wrapping it for
-- them (huddle_key_recipients → share_huddle_key) on foreground / huddle
-- open. Writes go through SECURITY DEFINER RPCs because the rules ("only for
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
-- join_huddle; then the usual checks, plus: nobody in the huddle has blocked
-- them. Returns the sealed huddle key for the caller's app to open with the
-- code's secret. A wrong code returns no row, so the miss is recorded.
create or replace function public.redeem_huddle_invite(p_lookup text, p_proof text, p_day_key text default null)
returns table (joined_huddle_id uuid, invite_salt text, invite_sealed_key text)
language plpgsql security definer set search_path = public as $$
declare
  v_invite huddle_invite_keys%rowtype;
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
  if (select count(*) from memberships m where m.huddle_id = v_invite.huddle_id) >= 8 then
    raise exception 'huddle_full';
  end if;
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

-- ============================================ already ran an older schema?
-- This file only builds a fresh database. To start over on one that ran an
-- earlier copy, run supabase/scripts/reset_database.sql (destructive), empty
-- the "deposits" bucket, then run this file again.
