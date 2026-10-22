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

Ship the app build with 008 and 009: run them first, and older builds keep
working (they keep joining with old codes until someone on the new build
opens that huddle, which retires its old code).
