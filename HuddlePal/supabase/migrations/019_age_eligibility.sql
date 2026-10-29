-- Confirm age before core app access, activate profiles atomically, and
-- make birthdays immutable. Existing rows stay intact; accounts without an
-- eligible birthday can read their own profile and save their birthday,
-- but cannot use the app's shared data. Safe to re-run.
begin;

revoke all on public.profile_birthdates from anon, authenticated;
grant select on public.profile_birthdates to authenticated;
drop policy if exists profile_birthdates_insert on public.profile_birthdates;
drop policy if exists profile_birthdates_update on public.profile_birthdates;

create or replace function public.caller_is_age_eligible()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profile_birthdates
    where user_id = auth.uid()
      and birth_date <= (((now() at time zone 'UTC')::date) - interval '13 years')::date
  );
$$;

create or replace function public.require_age_eligibility()
returns void
language plpgsql stable set search_path = public as $$
begin
  if not caller_is_age_eligible() then
    raise exception 'age_confirmation_required';
  end if;
end $$;

create or replace function public.save_birthday(p_birth_date date)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_saved date;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_birth_date is null or p_birth_date < date '1900-01-01' then
    raise exception 'invalid_birthday';
  end if;
  if p_birth_date > (((now() at time zone 'UTC')::date) - interval '13 years')::date then
    raise exception 'under_minimum_age';
  end if;
  -- All activations of this account serialize, including profile creation.
  perform 1 from auth.users where id = auth.uid() for update;
  if not exists (select 1 from profiles where id = auth.uid()) then
    raise exception 'profile_required';
  end if;
  select birth_date into v_saved from profile_birthdates where user_id = auth.uid();
  if found then
    if v_saved <> p_birth_date then raise exception 'birthday_immutable'; end if;
    return;
  end if;
  insert into profile_birthdates (user_id, birth_date) values (auth.uid(), p_birth_date);
end $$;

create or replace function public.complete_profile(
  p_display_name text, p_avatar_color_hex text, p_birth_date date
)
returns setof public.profiles
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  perform 1 from auth.users where id = auth.uid() for update;
  insert into profiles (id, display_name, avatar_color_hex)
    values (auth.uid(), p_display_name, p_avatar_color_hex)
    on conflict (id) do nothing;
  perform save_birthday(p_birth_date);
  return query select * from profiles where id = auth.uid();
end $$;

create or replace function public.is_huddle_member(v uuid)
returns boolean
language sql stable security definer set search_path = public as
$$ select caller_is_age_eligible() and exists (select 1 from memberships where huddle_id = v and user_id = auth.uid()); $$;

create or replace function public.is_huddle_keeper(v uuid)
returns boolean
language sql stable security definer set search_path = public as
$$ select caller_is_age_eligible() and exists (select 1 from memberships
                  where huddle_id = v and user_id = auth.uid() and role = 'keeper'); $$;

create or replace function public.shares_huddle_with(other uuid)
returns boolean
language sql stable security definer set search_path = public as
$$ select other = auth.uid() or (caller_is_age_eligible() and exists (
     select 1 from memberships m1
     join memberships m2 on m1.huddle_id = m2.huddle_id
     where m1.user_id = auth.uid() and m2.user_id = other)); $$;

create or replace function public.can_see_deposit(d uuid)
returns boolean
language sql stable security definer set search_path = public as
$$ select caller_is_age_eligible() and exists (select 1 from deposits dep
                  join memberships m on m.huddle_id = dep.huddle_id
                  where dep.id = d and m.user_id = auth.uid()); $$;

create or replace function public.caller_is_premium()
returns boolean
language sql stable security definer set search_path = public as
$$ select caller_is_age_eligible() and is_user_premium(auth.uid()); $$;

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
  where caller_is_age_eligible();
$$;

create or replace function public.holds_huddle_key(p_huddle uuid)
returns boolean
language sql stable security definer set search_path = public as
$$ select caller_is_age_eligible() and exists (select 1 from huddle_keys k
                  join user_keys u on u.user_id = k.user_id
                  where k.huddle_id = p_huddle and k.user_id = auth.uid()
                    and k.recipient_public_key = u.public_key); $$;

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
  perform require_age_eligibility();
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

create or replace function public.join_huddle(p_code text, p_day_key text default null)
returns setof public.huddles
language plpgsql security definer set search_path = public as $$
declare
  v_huddle huddles%rowtype;
  v_refusal text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  perform require_age_eligibility();
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

create or replace function public.redeem_huddle_invite(p_lookup text, p_proof text, p_day_key text default null)
returns table (joined_huddle_id uuid, invite_salt text, invite_sealed_key text)
language plpgsql security definer set search_path = public as $$
declare
  v_invite huddle_invite_keys%rowtype;
  v_refusal text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  perform require_age_eligibility();
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

revoke execute on function public.save_birthday(date) from public, anon;
grant execute on function public.save_birthday(date) to authenticated;
revoke execute on function public.complete_profile(text, text, date) from public, anon;
grant execute on function public.complete_profile(text, text, date) to authenticated;

drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles for insert
  with check (id = auth.uid() and caller_is_age_eligible());
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update
  using (id = auth.uid() and caller_is_age_eligible())
  with check (id = auth.uid() and caller_is_age_eligible());

-- An additional restrictive policy makes age approval a prerequisite for
-- every existing client operation, including those on otherwise owner-only
-- tables. Service-role cleanup and Apple notifications still bypass RLS.
do $$
declare
  t text;
begin
  foreach t in array array[
    'huddles', 'memberships', 'deposits', 'reactions', 'comments', 'skips',
    'reports', 'blocks', 'user_keys', 'huddle_keys', 'device_tokens', 'terms_acceptances'
  ] loop
    execute format('drop policy if exists age_eligibility on public.%I', t);
    execute format('create policy age_eligibility on public.%I as restrictive for all to authenticated using (public.caller_is_age_eligible()) with check (public.caller_is_age_eligible())', t);
  end loop;
end $$;
drop policy if exists deposits_storage_age_eligibility on storage.objects;
create policy deposits_storage_age_eligibility on storage.objects
  as restrictive for all to authenticated
  using (public.caller_is_age_eligible())
  with check (public.caller_is_age_eligible());


-- Existing tokens cannot reveal huddle metadata before age approval.
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
     and exists (
       select 1 from profile_birthdates approved
        where approved.user_id = t.user_id
          and approved.birth_date <= (((now() at time zone 'UTC')::date) - interval '13 years')::date
     )
     and not exists (
       select 1 from device_tokens newer
        where newer.token = t.token and newer.user_id <> t.user_id
          and (newer.updated_at, newer.user_id) > (t.updated_at, t.user_id)
     );
$$;

notify pgrst, 'reload schema';

commit;
