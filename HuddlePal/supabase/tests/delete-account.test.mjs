// The delete-account edge function (QA-20): Apple token revocation and the
// order and failure handling of the deletion steps. Runs the function's own
// TypeScript (Node strips the types) against a fake Apple and fake Supabase
// services; the database side of deletion is in rpc.test.mjs.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  AppleError, appleConfigFromEnv, makeClientSecret, revokeWithAuthorizationCode,
} from '../functions/delete-account/apple.ts'
import { handleDeleteAccount } from '../functions/delete-account/handler.ts'

const APPLE_USER = '000123.abcdef0123456789.0042'
const CODE = 'c0de.from.apple'
const REFRESH = 'r.refresh-token'

const b64url = (bytes) => Buffer.from(bytes).toString('base64url')
const decode = (part) => JSON.parse(Buffer.from(part, 'base64url').toString('utf8'))

/** A Sign in with Apple key as Apple hands it out: a PKCS#8 .p8 file. */
async function appleKey() {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
  const der = Buffer.from(await crypto.subtle.exportKey('pkcs8', pair.privateKey)).toString('base64')
  const pem = `-----BEGIN PRIVATE KEY-----\n${der.match(/.{1,64}/g).join('\n')}\n-----END PRIVATE KEY-----\n`
  return { pem, publicKey: pair.publicKey }
}

async function appleConfig() {
  const { pem, publicKey } = await appleKey()
  return { config: { teamId: 'TEAM123456', keyId: 'KEY1234567', clientId: 'com.huddlepals.ios', privateKey: pem }, publicKey }
}

const idToken = (sub) => `${b64url('{"alg":"RS256"}')}.${b64url(JSON.stringify({ sub, aud: 'com.huddlepals.ios' }))}.sig`

/** Stands in for appleid.apple.com, recording every request. */
function fakeApple({ token = { status: 200, body: { access_token: 'a', refresh_token: REFRESH, id_token: idToken(APPLE_USER) } }, revoke = { status: 200, body: '' } } = {}) {
  const calls = []
  const fetch = async (url, init) => {
    calls.push({ url: String(url), method: init.method, headers: init.headers, form: Object.fromEntries(new URLSearchParams(init.body)) })
    if (String(url).endsWith('/auth/token')) {
      if (token instanceof Error) throw token
      return new Response(JSON.stringify(token.body), { status: token.status })
    }
    return new Response(typeof revoke.body === 'string' ? revoke.body : JSON.stringify(revoke.body), { status: revoke.status })
  }
  return { calls, fetch }
}

describe('Apple client secret', () => {
  it('is an ES256 JWT for this app, signed with the Sign in with Apple key', async () => {
    const { config, publicKey } = await appleConfig()
    const jwt = await makeClientSecret(config, 1_800_000_000)
    const [header, claims, signature] = jwt.split('.')
    assert.deepEqual(decode(header), { alg: 'ES256', kid: 'KEY1234567' })
    assert.deepEqual(decode(claims), {
      iss: 'TEAM123456', iat: 1_800_000_000, exp: 1_800_000_300, aud: 'https://appleid.apple.com', sub: 'com.huddlepals.ios',
    })
    const valid = await crypto.subtle.verify(
      { name: 'ECDSA', hash: 'SHA-256' }, publicKey, Buffer.from(signature, 'base64url'), new TextEncoder().encode(`${header}.${claims}`),
    )
    assert.ok(valid, 'the signature verifies with the key’s public half')
  })

  it('accepts a .p8 pasted with escaped newlines', async () => {
    const { config, publicKey } = await appleConfig()
    const jwt = await makeClientSecret({ ...config, privateKey: config.privateKey.replace(/\n/g, '\\n') })
    const [header, claims, signature] = jwt.split('.')
    assert.ok(await crypto.subtle.verify(
      { name: 'ECDSA', hash: 'SHA-256' }, publicKey, Buffer.from(signature, 'base64url'), new TextEncoder().encode(`${header}.${claims}`),
    ))
  })

  it('reads the four APPLE_* secrets, and needs all of them', () => {
    const env = { APPLE_TEAM_ID: 't', APPLE_KEY_ID: 'k', APPLE_CLIENT_ID: 'c', APPLE_PRIVATE_KEY: 'p' }
    assert.deepEqual(appleConfigFromEnv((n) => env[n]), { teamId: 't', keyId: 'k', clientId: 'c', privateKey: 'p' })
    for (const missing of Object.keys(env)) {
      assert.equal(appleConfigFromEnv((n) => (n === missing ? undefined : env[n])), null, missing)
    }
  })
})

describe('revoking with an authorization code', () => {
  it('exchanges the code at /auth/token, then revokes the refresh token at /auth/revoke', async () => {
    const { config } = await appleConfig()
    const apple = fakeApple()
    assert.equal(await revokeWithAuthorizationCode(CODE, config, [APPLE_USER], apple.fetch), 'revoked')

    assert.deepEqual(apple.calls.map((c) => [c.method, c.url]), [
      ['POST', 'https://appleid.apple.com/auth/token'],
      ['POST', 'https://appleid.apple.com/auth/revoke'],
    ])
    for (const call of apple.calls) assert.equal(call.headers['Content-Type'], 'application/x-www-form-urlencoded')
    const [exchange, revoke] = apple.calls.map((c) => c.form)
    assert.equal(exchange.client_secret.split('.').length, 3)
    assert.deepEqual({ ...exchange, client_secret: 'jwt' }, {
      client_id: 'com.huddlepals.ios', client_secret: 'jwt', code: CODE, grant_type: 'authorization_code',
    })
    assert.deepEqual(revoke, {
      client_id: 'com.huddlepals.ios', client_secret: exchange.client_secret, token: REFRESH, token_type_hint: 'refresh_token',
    })
  })

  it('a code issued to a different Apple Account revokes nothing', async () => {
    const { config } = await appleConfig()
    const apple = fakeApple({ token: { status: 200, body: { refresh_token: REFRESH, id_token: idToken('someone-else') } } })
    assert.equal(await revokeWithAuthorizationCode(CODE, config, [APPLE_USER], apple.fetch), 'other_apple_id')
    assert.equal(apple.calls.length, 1, 'no revoke call')
  })

  it('Apple refusing the code (expired or used) is an AppleError, and nothing is revoked', async () => {
    const { config } = await appleConfig()
    const apple = fakeApple({ token: { status: 400, body: { error: 'invalid_grant' } } })
    await assert.rejects(revokeWithAuthorizationCode(CODE, config, [APPLE_USER], apple.fetch), (e) => {
      assert.ok(e instanceof AppleError)
      assert.deepEqual([e.step, e.status, e.code], ['token', 400, 'invalid_grant'])
      return true
    })
    assert.equal(apple.calls.length, 1)
  })

  it('a refused revoke is an AppleError', async () => {
    const { config } = await appleConfig()
    const apple = fakeApple({ revoke: { status: 400, body: { error: 'invalid_client' } } })
    await assert.rejects(revokeWithAuthorizationCode(CODE, config, [APPLE_USER], apple.fetch), /apple revoke 400 invalid_client/)
  })
})

describe('delete-account handler', () => {
  const appleUser = { id: 'user-1', identities: [{ provider: 'apple', id: APPLE_USER, identity_data: { sub: APPLE_USER } }] }

  async function setUp({ user = appleUser, apple = fakeApple(), withSecrets = true, fail = {} } = {}) {
    const { config } = await appleConfig()
    const steps = []
    const logs = []
    const step = (name) => async (userId) => {
      steps.push(`${name} ${userId}`)
      if (fail[name]) throw fail[name]
    }
    const services = {
      authenticate: async (token) => (token === 'valid-access-token' ? user : null),
      apple: withSecrets ? config : null,
      fetch: async (url, init) => {
        steps.push(`apple ${new URL(url).pathname}`)
        return apple.fetch(url, init)
      },
      removeAvatars: step('removeAvatars'),
      releaseStorageObjects: step('releaseStorageObjects'),
      deleteUser: step('deleteUser'),
      log: (event, detail) => logs.push(detail ? `${event} ${detail}` : event),
    }
    return { services, steps, logs, config }
  }

  const request = (body = { authorization_code: CODE }, { token = 'valid-access-token', method = 'POST' } = {}) =>
    new Request('https://project.functions.test/delete-account', {
      method,
      headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json' },
      body: method === 'POST' ? JSON.stringify(body) : undefined,
    })

  const allSteps = [
    'apple /auth/token', 'apple /auth/revoke',
    'removeAvatars user-1', 'releaseStorageObjects user-1', 'deleteUser user-1',
  ]

  it('revokes the Apple tokens, removes avatars, releases photos, then deletes the user', async () => {
    const { services, steps, logs } = await setUp()
    const response = await handleDeleteAccount(request(), services)
    assert.equal(response.status, 200)
    assert.deepEqual(await response.json(), { ok: true })
    assert.deepEqual(steps, allSteps)
    assert.deepEqual(logs, ['apple_revoked'])
  })

  it('still deletes the account when Apple refuses the code, and logs why', async () => {
    const { services, steps, logs } = await setUp({ apple: fakeApple({ token: { status: 400, body: { error: 'invalid_grant' } } }) })
    const response = await handleDeleteAccount(request(), services)
    assert.equal(response.status, 200)
    assert.deepEqual(steps, ['apple /auth/token', ...allSteps.slice(2)])
    assert.deepEqual(logs, ['apple_revoke_failed apple token 400 invalid_grant'])
  })

  it('still deletes the account when Apple can’t be reached', async () => {
    const { services, steps, logs } = await setUp({ apple: fakeApple({ token: new TypeError('fetch failed') }) })
    const response = await handleDeleteAccount(request(), services)
    assert.equal(response.status, 200)
    assert.ok(steps.includes('deleteUser user-1'))
    assert.deepEqual(logs, ['apple_revoke_failed TypeError: fetch failed'])
  })

  it('never logs the code, Apple’s tokens, or the key', async () => {
    for (const apple of [fakeApple(), fakeApple({ revoke: { status: 400, body: { error: 'invalid_request' } } })]) {
      const { services, logs, config } = await setUp({ apple })
      await handleDeleteAccount(request(), services)
      const logged = logs.join('\n')
      for (const secret of [CODE, REFRESH, config.privateKey.split('\n')[1]]) assert.ok(!logged.includes(secret))
    }
  })

  it('deletes without calling Apple when there is no code (older app), no secrets, or no Apple identity', async () => {
    const cases = [
      [{}, {}, 'apple_revoke_skipped: no authorization code'],
      [{ authorization_code: 'x'.repeat(513) }, {}, 'apple_revoke_skipped: no authorization code'],
      [{ authorization_code: CODE }, { withSecrets: false }, 'apple_revoke_skipped: APPLE_* secrets not set'],
      [{ authorization_code: CODE }, { user: { id: 'user-1', identities: [{ provider: 'email' }] } }, 'apple_revoke_skipped: not an Apple account'],
    ]
    for (const [body, options, expectedLog] of cases) {
      const { services, steps, logs } = await setUp(options)
      const response = await handleDeleteAccount(request(body), services)
      assert.equal(response.status, 200, expectedLog)
      assert.deepEqual(steps, allSteps.slice(2), expectedLog)
      assert.deepEqual(logs, [expectedLog])
    }
  })

  it('a body that isn’t JSON is treated as no code', async () => {
    const { services, steps } = await setUp()
    const req = new Request('https://project.functions.test/delete-account', {
      method: 'POST', headers: { Authorization: 'Bearer valid-access-token' }, body: 'not json',
    })
    assert.equal((await handleDeleteAccount(req, services)).status, 200)
    assert.deepEqual(steps, allSteps.slice(2))
  })

  it('a failed avatar cleanup or release is logged and the deletion goes on', async () => {
    const { services, steps, logs } = await setUp({
      fail: { removeAvatars: new Error('storage down'), releaseStorageObjects: new Error('function missing') },
    })
    const response = await handleDeleteAccount(request(), services)
    assert.equal(response.status, 200)
    assert.deepEqual(steps, allSteps)
    assert.deepEqual(logs.slice(1), ['avatar_cleanup_failed Error: storage down', 'storage_release_failed Error: function missing'])
  })

  it('a failed deleteUser is a 500 that shows the client no internal detail', async () => {
    const { services, logs } = await setUp({ fail: { deleteUser: new Error('Database error deleting user') } })
    const response = await handleDeleteAccount(request(), services)
    assert.equal(response.status, 500)
    assert.deepEqual(await response.json(), { error: 'delete_failed' })
    assert.ok(logs.includes('delete_failed Database error deleting user'), 'the detail stays in the server log')
  })

  it('refuses a caller without a valid access token, and touches nothing', async () => {
    for (const token of [null, 'expired-or-forged']) {
      const { services, steps } = await setUp()
      const response = await handleDeleteAccount(request(undefined, { token }), services)
      assert.equal(response.status, 401)
      assert.deepEqual(steps, [])
    }
  })

  it('answers only POST', async () => {
    const { services, steps } = await setUp()
    assert.equal((await handleDeleteAccount(request(undefined, { method: 'GET' }), services)).status, 405)
    assert.equal((await handleDeleteAccount(request(undefined, { method: 'OPTIONS' }), services)).status, 200)
    assert.deepEqual(steps, [])
  })
})
