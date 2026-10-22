-- Instant join. An invite code now carries a secret, and the huddle key
-- travels with it, sealed so that only someone holding the code can open it:
-- a new member sees every photo the moment they join, with nobody else
-- online, and the server still never holds a key that opens a photo.
--
--   huddles.invite_code     for a new-format invite, the code's 6-character
--                           lookup part, the only part the server stores.
--   huddles.legacy_invite   true while invite_code is still an old
--                           secret-less code. Old app builds keep joining
--                           with it until a member opens the huddle in the
--                           new build, which issues a new-format invite and
--                           retires the old code for good.
--   huddle_invite_keys      the active invite: the huddle key sealed with a
--                           key derived from the code's secret, and the
--                           secret sealed with the huddle key (so members'
--                           apps can show the code). Nobody reads it
--                           directly; redeem_huddle_invite hands the sealed
--                           key to whoever proves they hold the code.
--
-- Safe to re-run.

begin;

alter table public.huddles add column if not exists legacy_invite boolean not null default true;

create table if not exists public.huddle_invite_keys (
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

-- Old secret-less codes only. A huddle with a new-format invite (or one
-- that was reset) has legacy_invite = false, and its 6-character lookup is
-- no code at all on its own.
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

commit;
