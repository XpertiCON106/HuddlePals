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
