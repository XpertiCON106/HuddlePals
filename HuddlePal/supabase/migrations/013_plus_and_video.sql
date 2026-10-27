-- HuddlePals Plus and video drops. On the free plan an account keeps up to 3
-- huddles, and a huddle whose keeper is on it takes up to 4 members. Plus
-- (an App Store subscription, checked by the verify-subscription and
-- app-store-notifications edge functions) keeps up to 10 huddles of up to 10
-- members and can post a video clip of up to 6 seconds as the day's deposit.
-- When a subscription ends nobody is removed and nothing is deleted: only new
-- joins and new huddles are held back.
--
-- The free plan's limits apply as soon as this runs. Safe to re-run.

begin;

-- ================================================ no limits switch

-- An earlier copy of this migration switched the free plan's limits on at a
-- set time. They now always apply; running it again removes the switch.
drop function if exists public.free_limits_active();
drop table if exists public.app_limits;

-- ===================================================== subscriptions

-- What Apple says about each subscription, written only by the edge
-- functions (service role) after checking Apple's signature. One Apple
-- subscription entitles one HuddlePals account. Goes with the account.
create table if not exists public.user_entitlements (
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
create index if not exists user_entitlements_user on public.user_entitlements (user_id);
alter table public.user_entitlements enable row level security;
revoke all on public.user_entitlements from anon, authenticated;

-- App Store Server Notifications received, kept 90 days: which arrived and
-- when, nothing more. What they said is applied to user_entitlements.
create table if not exists public.app_store_notifications (
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

-- (Its columns changed: replaced, not altered.)
drop function if exists public.my_entitlement();
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

-- ======================================================== keepers

-- When each keeper became the keeper. The free plan takes new members only
-- into the 3 huddles its keeper has kept longest, so a huddle someone
-- inherits joins the back of that queue instead of pushing their own out.
alter table public.memberships add column if not exists keeper_since timestamptz;
-- Keepers so far: since they joined. Exact for the huddles' creators; the
-- best record there is for anyone who took over.
update public.memberships set keeper_since = joined_at where role = 'keeper' and keeper_since is null;

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

-- ================================================== huddle limits

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

-- An account keeps up to 3 huddles on the free plan and 10 with Plus,
-- inherited ones included. Locking the caller's
-- profile row serializes their creates, so two at once can't both pass.
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

-- Old secret-less codes. The joiner's and the huddle's rows are locked
-- before anything is counted, so two people joining at once can't both take
-- the last place, and nobody passes the 25-huddle limit by joining two at once.
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

-- New-format invites, under the same limits and locks as join_huddle.
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

-- ======================================================= video drops

-- A video deposit is two Storage objects sealed with the same photo key: its
-- poster, a JPEG at storage_path as for any photo (so app builds from before
-- videos show it as a photo), and the clip, an MP4 at video_path, the same
-- path ending in .mp4. Posting one takes Plus; it stays once Plus ends.
alter table public.deposits add column if not exists media_type text not null default 'photo'
  constraint deposits_media_type_check check (media_type in ('photo', 'video'));
alter table public.deposits add column if not exists duration_ms int
  constraint deposits_duration_ms_check check (duration_ms between 1 and 6100);
alter table public.deposits add column if not exists video_path text;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'deposits_video_check') then
    alter table public.deposits add constraint deposits_video_check check (
      (media_type = 'video') = (video_path is not null)
      and (duration_ms is null or media_type = 'video')
      and (video_path is null or video_path = regexp_replace(storage_path, '\.jpg$', '.mp4', 'i'))
    );
  end if;
end $$;

drop policy if exists deposits_insert on public.deposits;
create policy deposits_insert on public.deposits for insert
  with check (
    author_id = auth.uid()
    and is_huddle_member(huddle_id)
    and day_key >= to_char(now() - interval '2 days', 'YYYY-MM-DD')
    and day_key <= to_char(now() + interval '1 day',  'YYYY-MM-DD')
    and (media_type = 'photo' or caller_is_premium())
  );

drop policy if exists deposits_storage_insert on storage.objects;
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

-- Removing a reported video keeps its clip's path with the poster's.
alter table public.preserved_photos add column if not exists media_type text not null default 'photo';
alter table public.preserved_photos add column if not exists video_path text;

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

commit;
