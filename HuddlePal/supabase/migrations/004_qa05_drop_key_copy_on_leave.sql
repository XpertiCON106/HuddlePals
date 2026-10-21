-- QA-05: a member who left a huddle kept their wrapped copy of its key on
-- the server, readable by them forever. Leaving now removes it, and copies
-- held by people who already left are deleted. Safe to re-run.

begin;

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

delete from huddle_keys k
  where not exists (select 1 from memberships m where m.huddle_id = k.huddle_id and m.user_id = k.user_id);

commit;
