-- =============================================================================
-- DESTRUCTIVE. TEST DATA ONLY. DO NOT RUN AGAINST A DATABASE YOU NEED TO KEEP.
-- =============================================================================
--
-- Wipes every app-owned row and every object in the "deposits" storage
-- bucket. Photos sealed with the previous encryption labels cannot be
-- decrypted after this rename, so leaving them in place only produces
-- locked, unreadable deposits.
--
-- Does NOT delete auth.users, does NOT drop tables, and does NOT delete
-- the "deposits" bucket itself. Run this yourself in the SQL editor after
-- the huddle rename migration. This file is not a migration and must not
-- be applied automatically.
--
-- Child rows go first so foreign keys are satisfied without cascading into
-- auth.users.

begin;

delete from public.reactions;
delete from public.comments;
delete from public.reports;
delete from public.blocks;
delete from public.skips;
delete from public.deposits;
delete from public.memberships;
delete from public.huddle_keys;
delete from public.user_keys;
delete from public.huddles;
delete from public.profiles;

-- Photo files in the `deposits` bucket must be removed through the Storage
-- API or dashboard. Supabase rejects direct deletes from storage.objects
-- (storage.protect_delete).

commit;
