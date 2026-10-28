-- A huddle's keeper can't leave it, only delete it (delete_huddle, for
-- everyone): leaving now deletes only a member's own row. The keeper's row
-- still goes when their account is deleted or the huddle is, and the
-- longest-standing member still takes over when the keeper's account goes
-- (handle_membership_removed). Safe to re-run.

begin;

drop policy if exists memberships_delete on public.memberships;
create policy memberships_delete on public.memberships for delete
  using (user_id = auth.uid() and role = 'member');

commit;
