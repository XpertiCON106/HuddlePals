-- Vault — Supabase schema, RLS, and RPCs.
-- Run this whole file once in the Supabase SQL editor (Dashboard → SQL → New query).
-- Prereqs (Dashboard): Auth providers per DEPLOYMENT.md (email template
-- with {{ .Token }}, Apple client id, optional Twilio for SMS), and
-- Storage → create PRIVATE bucket named "deposits".

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

create table public.vaults (
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
  vault_id uuid not null references public.vaults (id) on delete cascade,
  role text not null default 'member' check (role in ('keeper', 'member')),
  skip_tokens_remaining int not null default 2 check (skip_tokens_remaining >= 0),
  joined_at timestamptz not null default now(),
  unique (user_id, vault_id)
);

create table public.deposits (
  id uuid primary key default gen_random_uuid(),
  vault_id uuid not null references public.vaults (id) on delete cascade,
  -- Nullable + SET NULL: deposited photos are permanent and stay in the
  -- vault's shared archive after the author deletes their account; the row
  -- survives with a null author, rendered as "Former member".
  author_id uuid references public.profiles (id) on delete set null,
  storage_path text not null,
  caption text check (caption is null or char_length(caption) <= 80),
  day_key text not null check (day_key ~ '^\d{4}-\d{2}-\d{2}$'),
  created_at timestamptz not null default now(),
  -- Once-and-permanent: one deposit per member per vault per day; a second
  -- insert fails atomically on this constraint.
  unique (vault_id, author_id, day_key)
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
  vault_id uuid not null references public.vaults (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  day_key text not null check (day_key ~ '^\d{4}-\d{2}-\d{2}$'),
  created_at timestamptz not null default now(),
  unique (vault_id, user_id, day_key)
);

create index deposits_vault_day on public.deposits (vault_id, day_key);
create index memberships_user on public.memberships (user_id);
create index reactions_deposit on public.reactions (deposit_id);
create index comments_deposit on public.comments (deposit_id);

-- ==================================================== helper functions
-- SECURITY DEFINER so policies can consult memberships without tripping
-- RLS recursion (the classic memberships-policy-reads-memberships trap).

create or replace function public.is_vault_member(v uuid)
returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from memberships where vault_id = v and user_id = auth.uid()); $$;

create or replace function public.is_vault_keeper(v uuid)
returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from memberships
                  where vault_id = v and user_id = auth.uid() and role = 'keeper'); $$;

create or replace function public.shares_vault_with(other uuid)
returns boolean
language sql stable security definer set search_path = public as
$$ select other = auth.uid() or exists (
     select 1 from memberships m1
     join memberships m2 on m1.vault_id = m2.vault_id
     where m1.user_id = auth.uid() and m2.user_id = other); $$;

create or replace function public.can_see_deposit(d uuid)
returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from deposits dep
                  join memberships m on m.vault_id = dep.vault_id
                  where dep.id = d and m.user_id = auth.uid()); $$;

-- ============================================================== RLS

alter table public.profiles    enable row level security;
alter table public.vaults      enable row level security;
alter table public.memberships enable row level security;
alter table public.deposits    enable row level security;
alter table public.reactions   enable row level security;
alter table public.comments    enable row level security;
alter table public.skips       enable row level security;

-- profiles: yourself, plus anyone you share a vault with.
create policy profiles_select on public.profiles for select
  using (shares_vault_with(id));
create policy profiles_insert on public.profiles for insert
  with check (id = auth.uid());
create policy profiles_update on public.profiles for update
  using (id = auth.uid()) with check (id = auth.uid());

-- vaults: members read; keeper updates settings; create/join go through RPCs.
-- Column grant (below) further limits the keeper to presentational fields —
-- streak_count / invite_code are writable only by the SECURITY DEFINER RPCs.
create policy vaults_select on public.vaults for select
  using (is_vault_member(id));
create policy vaults_update on public.vaults for update
  using (is_vault_keeper(id)) with check (is_vault_keeper(id));

-- M1: RLS limits UPDATE to the keeper's own vault; this limits WHICH columns
-- they may write. streak_count / last_streak_day / invite_code are then
-- writable only by the SECURITY DEFINER RPCs (which run as the table owner
-- and bypass column grants). Stops a keeper forging the streak via PATCH.
revoke update on public.vaults from authenticated;
grant update (name, emoji, notification_hour) on public.vaults to authenticated;

-- memberships: visible to co-members; leaving deletes your own row.
-- Inserts happen only inside the create_vault / join_vault RPCs.
create policy memberships_select on public.memberships for select
  using (is_vault_member(vault_id));
create policy memberships_delete on public.memberships for delete
  using (user_id = auth.uid());

-- deposits: members read; you write only your own, only into your vaults,
-- and only for today-or-yesterday (the 48h backfill window, UTC-anchored —
-- generous by up to a day for non-UTC users, never blocks a legal deposit).
create policy deposits_select on public.deposits for select
  using (is_vault_member(vault_id));
create policy deposits_insert on public.deposits for insert
  with check (
    author_id = auth.uid()
    and is_vault_member(vault_id)
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
  using (is_vault_member(vault_id));

-- ============================================================== RPCs

-- Creates a vault plus its keeper membership atomically, with a unique
-- server-generated invite code (ambiguous glyphs excluded).
create or replace function public.create_vault(p_name text, p_emoji text)
returns setof public.vaults
language plpgsql security definer set search_path = public as $$
declare
  v_code text;
  v_vault vaults%rowtype;
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  loop
    v_code := '';
    -- Crypto-strength source (not the predictable `random()` PRNG); the
    -- small modulo bias over a 31-char alphabet is irrelevant for codes.
    for i in 1..6 loop
      v_code := v_code || substr(alphabet, 1 + (get_byte(gen_random_bytes(1), 0) % length(alphabet)), 1);
    end loop;
    exit when not exists (select 1 from vaults where invite_code = v_code);
  end loop;
  insert into vaults (name, emoji, invite_code) values (p_name, p_emoji, v_code)
    returning * into v_vault;
  insert into memberships (user_id, vault_id, role) values (auth.uid(), v_vault.id, 'keeper');
  return next v_vault;
end $$;

-- Validates the invite code and enforces the 8-member cap atomically.
create or replace function public.join_vault(p_code text)
returns setof public.vaults
language plpgsql security definer set search_path = public as $$
declare
  v_vault vaults%rowtype;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_vault from vaults where upper(invite_code) = upper(trim(p_code));
  if not found then raise exception 'invite_code_not_found'; end if;
  if exists (select 1 from memberships where vault_id = v_vault.id and user_id = auth.uid()) then
    raise exception 'already_member';
  end if;
  if (select count(*) from memberships where vault_id = v_vault.id) >= 8 then
    raise exception 'vault_full';
  end if;
  insert into memberships (user_id, vault_id) values (auth.uid(), v_vault.id);
  return next v_vault;
end $$;

-- Decrements the CALLER's token and records their skip, atomically.
-- `p_user` is accepted for signature stability but deliberately ignored:
-- the action always targets auth.uid(), so a member can never spend or
-- forge a skip on another member's behalf (was an IDOR).
create or replace function public.spend_skip_token(p_vault uuid, p_user uuid, p_day_key text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_vault_member(p_vault) then raise exception 'not_a_member'; end if;
  update memberships set skip_tokens_remaining = skip_tokens_remaining - 1
    where vault_id = p_vault and user_id = auth.uid() and skip_tokens_remaining > 0;
  if not found then raise exception 'no_tokens_remaining'; end if;
  insert into skips (vault_id, user_id, day_key) values (p_vault, auth.uid(), p_day_key)
    on conflict do nothing;
end $$;

-- Server-side group streak recompute — the single source of truth, so all
-- members agree. Mirrors VaultEngine.computeStreak: walk back from p_today
-- (the caller's local day) or yesterday; a day counts when every current
-- member deposited or skipped; an incomplete in-progress today never breaks
-- the streak. Returns the new count.
create or replace function public.recompute_streak(p_vault uuid, p_today text)
returns int
language plpgsql security definer set search_path = public as $$
declare
  v_members int;
  v_cursor date;
  v_count int := 0;
  v_last date := null;
  v_covered int;
begin
  if not is_vault_member(p_vault) then raise exception 'not_a_member'; end if;
  -- M1: don't trust an arbitrary client day. Clamp to ±1 day of server UTC
  -- (±1 absorbs legitimate timezone skew) so a member can't pass a bogus far
  -- date to grief the streak to 0.
  if p_today::date < (now()::date - 1) or p_today::date > (now()::date + 1) then
    raise exception 'invalid_day_key';
  end if;
  select count(*) into v_members from memberships where vault_id = p_vault;
  v_cursor := p_today::date;

  -- If today isn't complete yet, start counting from yesterday.
  select count(distinct u) into v_covered from (
    select author_id as u from deposits where vault_id = p_vault and day_key = to_char(v_cursor, 'YYYY-MM-DD')
    union
    select user_id from skips where vault_id = p_vault and day_key = to_char(v_cursor, 'YYYY-MM-DD')
  ) c join memberships m on m.vault_id = p_vault and m.user_id = c.u;
  if v_members = 0 or v_covered < v_members then
    v_cursor := v_cursor - 1;
  end if;

  loop
    select count(distinct u) into v_covered from (
      select author_id as u from deposits where vault_id = p_vault and day_key = to_char(v_cursor, 'YYYY-MM-DD')
      union
      select user_id from skips where vault_id = p_vault and day_key = to_char(v_cursor, 'YYYY-MM-DD')
    ) c join memberships m on m.vault_id = p_vault and m.user_id = c.u;
    exit when v_members = 0 or v_covered < v_members or v_count >= 36500;
    v_count := v_count + 1;
    if v_last is null then v_last := v_cursor; end if;
    v_cursor := v_cursor - 1;
  end loop;

  update vaults set streak_count = v_count,
                    last_streak_day = case when v_last is null then null
                                           else to_char(v_last, 'YYYY-MM-DD') end
    where id = p_vault;
  return v_count;
end $$;

-- ======================================================= storage RLS
-- One private bucket, "deposits", with two path namespaces:
--   "<vault_id>/<file>.jpg"          → vault photos, gated by membership
--   "avatars/<user_id>/<file>.jpg"   → profile photos: any signed-in user
--                                      may view; only the owner may write.

-- Safe uuid cast: the avatars namespace would otherwise crash the
-- vault-membership check ('avatars'::uuid raises).
create or replace function public.try_uuid(t text)
returns uuid
language plpgsql immutable as $$
begin
  return t::uuid;
exception when others then
  return null;
end $$;

create policy deposits_storage_read on storage.objects for select
  using (
    bucket_id = 'deposits' and (
      (storage.foldername(name))[1] = 'avatars'
      or (
        try_uuid((storage.foldername(name))[1]) is not null
        and is_vault_member(try_uuid((storage.foldername(name))[1]))
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
        and is_vault_member(try_uuid((storage.foldername(name))[1]))
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

-- blocks: fully managed by the blocker.
create policy blocks_select on public.blocks for select
  using (blocker_id = auth.uid());
create policy blocks_insert on public.blocks for insert
  with check (blocker_id = auth.uid());
create policy blocks_delete on public.blocks for delete
  using (blocker_id = auth.uid());

-- ============================================ already ran an older schema?
-- Idempotent migration for databases created before profiles/permanence:
--   alter table public.profiles add column if not exists bio text
--     check (bio is null or char_length(bio) <= 160);
--   alter table public.profiles add column if not exists photo_paths jsonb
--     not null default '[]'::jsonb;
--   drop policy if exists deposits_update on public.deposits;
--   drop policy if exists deposits_delete on public.deposits;
--   drop policy if exists deposits_storage_read on storage.objects;
--   drop policy if exists deposits_storage_insert on storage.objects;
--   drop policy if exists deposits_storage_update on storage.objects;
--   -- then re-run the "storage RLS" section above (and create try_uuid).

-- ============================================ security hardening migration
-- For a DB created before this hardening (H1/M1/M4/H2a), run:
--   create extension if not exists pgcrypto;
--   -- H1 + M1 + H2a: just re-run the create_vault, spend_skip_token, and
--   -- recompute_streak function definitions above (CREATE OR REPLACE).
--   -- M1 column grant:
--   revoke update on public.vaults from authenticated;
--   grant update (name, emoji, notification_hour) on public.vaults to authenticated;
--   -- M4: re-create the two update policies with WITH CHECK:
--   drop policy if exists profiles_update on public.profiles;
--   drop policy if exists vaults_update   on public.vaults;
--   -- then re-run the profiles_update / vaults_update policy statements above.

-- ========================================== account-deletion migration
-- For a DB created before "Former member" account deletion, repoint the FKs
-- so deleting a profile keeps deposits/comments (SET NULL) instead of
-- cascading them away:
--   alter table public.deposits alter column author_id drop not null;
--   alter table public.deposits drop constraint deposits_author_id_fkey,
--     add constraint deposits_author_id_fkey
--     foreign key (author_id) references public.profiles (id) on delete set null;
--   alter table public.comments alter column user_id drop not null;
--   alter table public.comments drop constraint comments_user_id_fkey,
--     add constraint comments_user_id_fkey
--     foreign key (user_id) references public.profiles (id) on delete set null;
-- (Constraint names assume Postgres defaults — verify with \d before running.)
