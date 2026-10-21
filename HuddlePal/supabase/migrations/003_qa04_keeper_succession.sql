-- QA-04: when a huddle's keeper left or deleted their account, nobody was
-- promoted, so the huddle could no longer be renamed or have its settings
-- changed. The longest-standing remaining member now becomes keeper. Also
-- repairs huddles that already lost their keeper. Safe to re-run.

begin;

-- A huddle always has a keeper: when the keeper leaves (or deletes their
-- account, which cascades here), the longest-standing remaining member
-- takes over. Runs as the table owner, since members can't update roles.
create or replace function public.handle_membership_removed()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.role = 'keeper'
     and not exists (select 1 from memberships where huddle_id = old.huddle_id and role = 'keeper') then
    update memberships set role = 'keeper'
      where id = (select id from memberships where huddle_id = old.huddle_id
                  order by joined_at, id limit 1);
  end if;
  return old;
end $$;

drop trigger if exists memberships_after_delete on public.memberships;
create trigger memberships_after_delete
  after delete on public.memberships
  for each row execute function public.handle_membership_removed();

-- Huddles that lost their keeper before this fix.
update memberships m set role = 'keeper'
  where m.id in (
    select distinct on (huddle_id) id from memberships
    where huddle_id not in (select huddle_id from memberships where role = 'keeper')
    order by huddle_id, joined_at, id
  );

commit;
