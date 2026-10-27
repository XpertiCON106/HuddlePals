// Certificate chains shaped like Apple's App Store signing chain, for
// app-store.test.mjs: a P-384 root, a P-384 intermediate carrying Apple's
// WWDR marker, and a P-256 leaf carrying the App Store signing marker. Built
// and signed here with node:crypto on every run, so no private key is ever
// committed; each piece can be bent to test one way a forgery could fail.

import { generateKeyPairSync, sign } from 'node:crypto'

export const WWDR_MARKER = '1.2.840.113635.100.6.2.1'
export const STORE_SIGNING_MARKER = '1.2.840.113635.100.6.11.1'
const DAY = 86_400_000

// Just enough DER to write a certificate.
const length = (n) => (n < 0x80 ? [n] : n < 0x100 ? [0x81, n] : [0x82, n >> 8, n & 0xff])
const tlv = (tag, ...parts) => {
  const body = Buffer.concat(parts.map((part) => Buffer.from(part)))
  return Buffer.concat([Buffer.from([tag, ...length(body.length)]), body])
}
const sequence = (...parts) => tlv(0x30, ...parts)
const set = (...parts) => tlv(0x31, ...parts)
const integer = (...bytes) => tlv(0x02, bytes)
const boolean = (value) => tlv(0x01, [value ? 0xff : 0x00])
const octets = (bytes) => tlv(0x04, bytes)
const bits = (bytes) => tlv(0x03, Buffer.concat([Buffer.from([0]), bytes]))
const explicit = (n, ...parts) => tlv(0xa0 + n, ...parts)
const NULL = Buffer.from([0x05, 0x00])

function oid(dotted) {
  const [a, b, ...rest] = dotted.split('.').map(Number)
  const bytes = [40 * a + b]
  for (const value of rest) {
    const encoded = [value & 0x7f]
    for (let v = Math.floor(value / 128); v > 0; v = Math.floor(v / 128)) encoded.unshift((v & 0x7f) | 0x80)
    bytes.push(...encoded)
  }
  return tlv(0x06, bytes)
}

function time(ms) {
  const digits = new Date(ms).toISOString().replace(/[-:T]/g, '').slice(0, 14)
  return new Date(ms).getUTCFullYear() < 2050 ? tlv(0x17, Buffer.from(`${digits.slice(2)}Z`)) : tlv(0x18, Buffer.from(`${digits}Z`))
}

const name = (commonName) => sequence(set(sequence(oid('2.5.4.3'), tlv(0x0c, Buffer.from(commonName)))))
const algorithm = (hash) => sequence(oid(hash === 'sha384' ? '1.2.840.10045.4.3.3' : '1.2.840.10045.4.3.2'))

export const ecKey = (curve = 'P-256') =>
  generateKeyPairSync('ec', { namedCurve: curve === 'P-384' ? 'secp384r1' : 'prime256v1' })

/** A DER X.509 v3 certificate for `publicKey`, signed with `signingKey`. */
export function certificate({
  subject, issuer = subject, publicKey, signingKey, hash = 'sha384',
  notBefore = Date.now() - DAY, notAfter = Date.now() + 365 * DAY, ca = false, markers = [], serial = 1,
}) {
  const extensions = [
    sequence(oid('2.5.29.19'), boolean(true), octets(sequence(...(ca ? [boolean(true)] : [])))),
    ...markers.map((marker) => sequence(oid(marker), octets(NULL))),
  ]
  const tbs = sequence(
    explicit(0, integer(2)),
    integer(serial),
    algorithm(hash),
    name(issuer),
    sequence(time(notBefore), time(notAfter)),
    name(subject),
    publicKey.export({ type: 'spki', format: 'der' }),
    explicit(3, sequence(...extensions)),
  )
  return sequence(tbs, algorithm(hash), bits(sign(hash, tbs, signingKey)))
}

const b64url = (value) => Buffer.from(typeof value === 'string' ? value : JSON.stringify(value)).toString('base64url')

/**
 * A root, intermediate and leaf like Apple's. Options bend one piece:
 * `leaf` / `intermediate` are passed on to certificate() for that one.
 * `sign(payload)` returns a JWS signed by the leaf with the chain in x5c.
 */
export function chain({ leaf: leafOptions = {}, intermediate: intermediateOptions = {}, leafCurve = 'P-256' } = {}) {
  const rootKey = ecKey('P-384')
  const intermediateKey = ecKey('P-384')
  const leafKey = ecKey(leafCurve)
  const root = certificate({ subject: 'Test Root CA - G3', publicKey: rootKey.publicKey, signingKey: rootKey.privateKey, ca: true })
  const intermediate = certificate({
    subject: 'Test WWDR CA', issuer: 'Test Root CA - G3', publicKey: intermediateKey.publicKey, signingKey: rootKey.privateKey,
    ca: true, markers: [WWDR_MARKER], ...intermediateOptions,
  })
  const leaf = certificate({
    subject: 'Test App Store Signing', issuer: 'Test WWDR CA', publicKey: leafKey.publicKey, signingKey: intermediateKey.privateKey,
    markers: [STORE_SIGNING_MARKER], ...leafOptions,
  })
  const x5c = [leaf, intermediate, root].map((der) => der.toString('base64'))
  return {
    root, intermediate, leaf, rootKey, intermediateKey, leafKey, x5c,
    rootCertificate: root.toString('base64'),
    /** A JWS of `payload`; `header` overrides header fields, `key` the signing key. */
    sign(payload, { header = {}, key = leafKey.privateKey } = {}) {
      const head = b64url({ alg: 'ES256', x5c, ...header })
      const body = b64url(payload)
      const signature = sign('sha256', Buffer.from(`${head}.${body}`), { key, dsaEncoding: 'ieee-p1363' })
      return `${head}.${body}.${signature.toString('base64url')}`
    },
  }
}
