# Migrations

`schema.sql` builds a fresh database. These files upgrade the database
production already runs (built from `schema.sql` as of commit `b1af561`)
without touching its data.

Apply them in filename order in the Supabase SQL editor. Each one is
idempotent and wrapped in a transaction, so re-running it is harmless.
`schema.sql` already contains every change listed here.

The tests in `../tests` run the whole suite twice, once on a fresh
`schema.sql` and once on the deployed schema plus these migrations, and check
that both end up identical (`npm test`).

| File | What it does |
| --- | --- |
| 001–007 | QA fixes (see each file's header) |
| `008_invite_keys.sql` | Instant join: invite codes carry the huddle key, sealed for the code's secret (`huddle_invite_keys`, `redeem_huddle_invite` and friends); old codes retire once a huddle has a new-format invite |
| `009_push_notifications.sql` | Push notifications: `device_tokens`, `push_targets`, and the `pg_net` triggers that call the `send-push` function (they do nothing until the Vault secrets in DEVELOPMENT.md exist) |
| `010_terms_acceptances.sql` | Which version of the Terms each account agreed to, and when (`terms_acceptances`), recorded by the app after sign-in |
| `011_keep_reports_after_account_deletion.sql` | A report outlives its reporter's account (`reporter_id` becomes null instead of the report being deleted), so reported photos stay reviewable for NCMEC's one-year preservation |
| `012_remove_reported_photo.sql` | Operator tool: `remove_reported_photo(id)` takes a reported photo out of its huddle and keeps what finds and opens it in `preserved_photos` for a year; `expired_preserved_photos()` lists what can then go |
| `013_plus_and_video.sql` | HuddlePals Plus and video drops: `user_entitlements` (written only by `apply_entitlement`, for the `verify-subscription` and `app-store-notifications` functions), `my_entitlement()`, the free plan's caps (`create_huddle`, `huddle_join_rule`, `huddle_join_status`, `memberships.keeper_since`), video deposits (`media_type`, `duration_ms`, `video_path`; posting one and uploading a `.mp4` take Plus), videos in `preserved_photos`, and `push_media_type` for the notification copy. The caps wait for `app_limits.free_limits_start` |

Ship the app build with 008 and 009: run them first, and older builds keep
working (they keep joining with old codes until someone on the new build
opens that huddle, which retires its old code).

Run 010 before shipping the build that records Terms agreements. Until the
table exists that build's recording fails quietly and retries on the next
launch. 011 changes nothing the app sees. Neither does 012, which only the
operator can call (SQL editor).

Run 013 before deploying `verify-subscription` and `app-store-notifications`
and before shipping the Plus build. Until `app_limits.free_limits_start` is
set it changes nothing for anyone without Plus: 8 members a huddle, no cap
on huddles, the same `huddle_full` error builds from before Plus already
explain. A Plus keeper's huddles take 10 from the start. Once
Plus is on sale, start the free limits after a grace period, in the SQL
editor (`null` turns them off again):

```sql
update public.app_limits set free_limits_start = '<launch + 14 days>';
```

From then on, join refusals all contain `blocked`, which builds from before
Plus show as "You can't join this huddle."
