// Live updates (migration 017): on Supabase, deposits, comments and
// reactions are in the supabase_realtime publication, which Realtime reads
// Postgres changes from. Without the publication (a plain Postgres), the
// migration does nothing.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

describe('live updates', () => {
  it('puts deposits, comments and reactions in the realtime publication, once', async () => {
    const { PGlite } = await import('@electric-sql/pglite')
    const { pgcrypto } = await import('@electric-sql/pglite/contrib/pgcrypto')
    const { STUB_SQL, DEPLOYED_SQL, migrations } = await import('./harness.mjs')
    const db = new PGlite({ extensions: { pgcrypto } })
    await db.exec(STUB_SQL)
    await db.exec('create publication supabase_realtime')
    await db.exec(DEPLOYED_SQL)
    // Twice: migrations must be safe to re-run.
    for (let pass = 0; pass < 2; pass++) {
      for (const { sql } of migrations()) await db.exec(sql)
    }
    const { rows } = await db.query(
      `select tablename from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' order by 1`,
    )
    assert.deepEqual(rows.map((r) => r.tablename), ['comments', 'deposits', 'reactions'])
  })
})
