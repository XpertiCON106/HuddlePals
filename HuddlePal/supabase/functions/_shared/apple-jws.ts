// Apple's signed App Store data: StoreKit 2 transactions and renewal info,
// and App Store Server Notifications V2. Each is a JWS whose header carries
// its certificate chain (x5c): the signing certificate, Apple's WWDR
// intermediate, and Apple Root CA - G3. It is genuine when that root is
// exactly the copy pinned below, each certificate is signed by the next one
// and valid now, the intermediate is a CA, both carry Apple's marker
// extensions, and the leaf signed the JWS (ES256). Revocation (OCSP) isn't
// checked, as in Apple's own App Store Server Library unless its online
// checks are turned on.
//
// Plain WebCrypto and a small DER reader, no runtime-specific imports: the
// edge functions run it on Deno, and supabase/tests runs it on Node
// (app-store.test.mjs).

/**
 * Apple Root CA - G3, DER as base64, from
 * https://www.apple.com/certificateauthority/ (byte for byte the copy in
 * macOS's system roots). SHA-256 fingerprint 63:34:3A:BF:B8:9A:6A:03:EB:B5:
 * 7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79.
 * Valid until April 30, 2039.
 */
export const APPLE_ROOT_CA_G3 =
  "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQL" +
  "DB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMw" +
  "MTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRp" +
  "ZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IA" +
  "BJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqX" +
  "l5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8w" +
  "DgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWT" +
  "xnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==";

const OID = {
  ecPublicKey: "1.2.840.10045.2.1",
  p256: "1.2.840.10045.3.1.7",
  p384: "1.3.132.0.34",
  ecdsaWithSha256: "1.2.840.10045.4.3.2",
  ecdsaWithSha384: "1.2.840.10045.4.3.3",
  basicConstraints: "2.5.29.19",
  /** Apple's marker on its WWDR intermediates. */
  appleWwdrIntermediate: "1.2.840.113635.100.6.2.1",
  /** Apple's marker on the App Store's signing certificates. */
  appleStoreSigning: "1.2.840.113635.100.6.11.1",
};

const CURVES: Record<string, { name: string; size: number }> = {
  [OID.p256]: { name: "P-256", size: 32 },
  [OID.p384]: { name: "P-384", size: 48 },
};

const HASHES: Record<string, string> = {
  [OID.ecdsaWithSha256]: "SHA-256",
  [OID.ecdsaWithSha384]: "SHA-384",
};

/** Why a JWS was refused. Carries nothing secret, so it's safe to log. */
export class JwsError extends Error {}

/**
 * The payload of `jws` once Apple's signature checks out; throws JwsError
 * otherwise. `rootCertificate` (base64 DER) is for tests; `now` (ms) is
 * when the certificates must be valid.
 */
export async function verifyAppleJws(
  jws: string,
  { rootCertificate = APPLE_ROOT_CA_G3, now = Date.now() }: { rootCertificate?: string; now?: number } = {},
): Promise<Record<string, unknown>> {
  const parts = typeof jws === "string" ? jws.split(".") : [];
  if (parts.length !== 3) throw new JwsError("jws: malformed");
  const header = parseJson(fromBase64url(parts[0]), "header");
  if (header.alg !== "ES256") throw new JwsError("jws: not ES256");
  const x5c = header.x5c;
  if (!Array.isArray(x5c) || x5c.length !== 3 || !x5c.every((c) => typeof c === "string")) {
    throw new JwsError("jws: no certificate chain");
  }
  const ders = x5c.map((c) => fromBase64(c as string));
  if (!sameBytes(ders[2], fromBase64(rootCertificate))) throw new JwsError("chain: not Apple's root");
  const [leaf, intermediate, root] = ders.map(parseCertificate);

  for (const [name, certificate] of [["leaf", leaf], ["intermediate", intermediate], ["root", root]] as const) {
    if (now < certificate.notBefore || now > certificate.notAfter) {
      throw new JwsError(`chain: ${name} certificate not valid now`);
    }
  }
  if (!intermediate.isCA || !intermediate.extensions.has(OID.appleWwdrIntermediate)) {
    throw new JwsError("chain: not Apple's intermediate");
  }
  if (leaf.isCA || !leaf.extensions.has(OID.appleStoreSigning)) {
    throw new JwsError("chain: not an App Store signing certificate");
  }
  if (!sameBytes(leaf.issuer, intermediate.subject) || !sameBytes(intermediate.issuer, root.subject)) {
    throw new JwsError("chain: names don't chain");
  }
  if (!(await isSignedBy(intermediate, root)) || !(await isSignedBy(leaf, intermediate))) {
    throw new JwsError("chain: bad certificate signature");
  }

  if (leaf.curve !== OID.p256) throw new JwsError("jws: signing key is not P-256");
  const signature = fromBase64url(parts[2]);
  if (signature.length !== 64) throw new JwsError("jws: bad signature");
  const key = await importKey(leaf.spki, "P-256");
  const valid = key !== null && await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    signature,
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
  if (!valid) throw new JwsError("jws: bad signature");
  return parseJson(fromBase64url(parts[1]), "payload");
}

// MARK: - Certificates

/** What this file reads from an X.509 certificate. */
export interface Certificate {
  /** The signed part (tbsCertificate), exactly as encoded. */
  tbs: Uint8Array;
  signatureAlgorithm: string;
  /** DER ECDSA-Sig-Value. */
  signature: Uint8Array;
  issuer: Uint8Array;
  subject: Uint8Array;
  /** Milliseconds since 1970. */
  notBefore: number;
  notAfter: number;
  /** DER SubjectPublicKeyInfo, as WebCrypto imports it. */
  spki: Uint8Array;
  /** The EC key's named curve (OID). */
  curve: string;
  isCA: boolean;
  /** OIDs of every extension. */
  extensions: Set<string>;
}

/** Parses a DER certificate with an EC key; throws JwsError on anything else. */
export function parseCertificate(der: Uint8Array): Certificate {
  const certificate = expect(readNode(der, 0), 0x30, "certificate");
  if (certificate.end !== der.length) throw new JwsError("certificate: trailing data");
  const [tbsNode, algorithmNode, signatureNode] = childrenOf(der, certificate);
  const fields = childrenOf(der, expect(tbsNode, 0x30, "tbsCertificate"));
  // [0] version, serialNumber, signature: skipped (the signature covers them).
  let at = fields[0]?.tag === 0xa0 ? 3 : 2;
  const issuer = expect(fields[at++], 0x30, "issuer");
  const [notBefore, notAfter] = childrenOf(der, expect(fields[at++], 0x30, "validity"));
  const subject = expect(fields[at++], 0x30, "subject");
  const spki = expect(fields[at++], 0x30, "public key");
  const [keyAlgorithm] = childrenOf(der, spki);
  const [keyType, curve] = childrenOf(der, expect(keyAlgorithm, 0x30, "key algorithm"));
  if (oidOf(der, keyType) !== OID.ecPublicKey) throw new JwsError("certificate: not an EC key");

  const extensions = new Set<string>();
  let isCA = false;
  for (const field of fields.slice(at)) {
    if (field.tag !== 0xa3) continue;
    const [list] = childrenOf(der, field);
    for (const extension of childrenOf(der, expect(list, 0x30, "extensions"))) {
      const parts = childrenOf(der, expect(extension, 0x30, "extension"));
      const id = oidOf(der, parts[0]);
      extensions.add(id);
      if (id === OID.basicConstraints) {
        const value = expect(parts[parts.length - 1], 0x04, "extension value");
        const constraints = expect(readNode(der, value.contentStart, value.end), 0x30, "basic constraints");
        const [flag] = childrenOf(der, constraints);
        isCA = flag?.tag === 0x01 && der[flag.contentStart] !== 0;
      }
    }
  }

  const [signatureAlgorithm] = childrenOf(der, expect(algorithmNode, 0x30, "signature algorithm"));
  expect(signatureNode, 0x03, "signature");
  if (der[signatureNode.contentStart] !== 0) throw new JwsError("certificate: bad signature");
  return {
    tbs: der.subarray(tbsNode.start, tbsNode.end),
    signatureAlgorithm: oidOf(der, signatureAlgorithm),
    signature: der.subarray(signatureNode.contentStart + 1, signatureNode.end),
    issuer: der.subarray(issuer.start, issuer.end),
    subject: der.subarray(subject.start, subject.end),
    notBefore: timeOf(der, notBefore),
    notAfter: timeOf(der, notAfter),
    spki: der.subarray(spki.start, spki.end),
    curve: oidOf(der, curve),
    isCA,
    extensions,
  };
}

/** Whether `issuer`'s key signed `certificate`. */
export async function isSignedBy(certificate: Certificate, issuer: Certificate): Promise<boolean> {
  const hash = HASHES[certificate.signatureAlgorithm];
  const curve = CURVES[issuer.curve];
  if (!hash || !curve) return false;
  const key = await importKey(issuer.spki, curve.name);
  if (!key) return false;
  let signature: Uint8Array;
  try {
    signature = rawSignature(certificate.signature, curve.size);
  } catch {
    return false;
  }
  return crypto.subtle.verify({ name: "ECDSA", hash }, key, signature, certificate.tbs);
}

/** An EC public key for verifying; null when the certificate's key is malformed. */
async function importKey(spki: Uint8Array, curve: string): Promise<CryptoKey | null> {
  try {
    return await crypto.subtle.importKey("spki", spki, { name: "ECDSA", namedCurve: curve }, false, ["verify"]);
  } catch {
    return null;
  }
}

// MARK: - DER

interface Node {
  tag: number;
  start: number;
  contentStart: number;
  end: number;
}

function readNode(bytes: Uint8Array, offset: number, limit = bytes.length): Node {
  if (offset + 2 > limit) throw new JwsError("der: truncated");
  const tag = bytes[offset];
  if ((tag & 0x1f) === 0x1f) throw new JwsError("der: unsupported tag");
  let length = bytes[offset + 1];
  let contentStart = offset + 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count === 0 || count > 3 || contentStart + count > limit) throw new JwsError("der: bad length");
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + bytes[contentStart + i];
    contentStart += count;
  }
  const end = contentStart + length;
  if (end > limit) throw new JwsError("der: truncated");
  return { tag, start: offset, contentStart, end };
}

function childrenOf(bytes: Uint8Array, node: Node): Node[] {
  const children: Node[] = [];
  for (let at = node.contentStart; at < node.end;) {
    const child = readNode(bytes, at, node.end);
    children.push(child);
    at = child.end;
  }
  return children;
}

function expect(node: Node | undefined, tag: number, what: string): Node {
  if (!node || node.tag !== tag) throw new JwsError(`der: bad ${what}`);
  return node;
}

function oidOf(bytes: Uint8Array, node: Node | undefined): string {
  const oid = expect(node, 0x06, "object identifier");
  const values: number[] = [];
  let value = 0;
  for (let i = oid.contentStart; i < oid.end; i++) {
    value = value * 128 + (bytes[i] & 0x7f);
    if (!(bytes[i] & 0x80)) {
      values.push(value);
      value = 0;
    }
  }
  if (values.length === 0) throw new JwsError("der: bad object identifier");
  const first = values.shift()!;
  const head = first < 80 ? [Math.floor(first / 40), first % 40] : [2, first - 80];
  return [...head, ...values].join(".");
}

/** UTCTime or GeneralizedTime, in UTC ("Z"), as milliseconds since 1970. */
function timeOf(bytes: Uint8Array, node: Node | undefined): number {
  if (!node) throw new JwsError("der: no time");
  const text = String.fromCharCode(...bytes.subarray(node.contentStart, node.end));
  const match = node.tag === 0x17
    ? /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text)
    : node.tag === 0x18
    ? /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text)
    : null;
  if (!match) throw new JwsError("der: bad time");
  const [year, month, day, hour, minute, second] = match.slice(1).map(Number);
  const fullYear = node.tag === 0x17 ? (year < 50 ? 2000 + year : 1900 + year) : year;
  return Date.UTC(fullYear, month - 1, day, hour, minute, second);
}

/** DER ECDSA-Sig-Value → r ‖ s, each `size` bytes, as WebCrypto takes it. */
function rawSignature(der: Uint8Array, size: number): Uint8Array {
  const sequence = expect(readNode(der, 0), 0x30, "signature");
  if (sequence.end !== der.length) throw new JwsError("der: bad signature");
  const integers = childrenOf(der, sequence);
  if (integers.length !== 2) throw new JwsError("der: bad signature");
  const raw = new Uint8Array(size * 2);
  integers.forEach((node, k) => {
    expect(node, 0x02, "signature");
    let value = der.subarray(node.contentStart, node.end);
    while (value.length > size && value[0] === 0) value = value.subarray(1);
    if (value.length > size) throw new JwsError("der: bad signature");
    raw.set(value, k * size + size - value.length);
  });
  return raw;
}

// MARK: - Encoding

function fromBase64(text: string): Uint8Array {
  let binary: string;
  try {
    binary = atob(text);
  } catch {
    throw new JwsError("base64: malformed");
  }
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function fromBase64url(text: string): Uint8Array {
  const base64 = text.replace(/-/g, "+").replace(/_/g, "/");
  return fromBase64(base64 + "=".repeat((4 - (base64.length % 4)) % 4));
}

function parseJson(bytes: Uint8Array, what: string): Record<string, unknown> {
  try {
    const value = JSON.parse(new TextDecoder().decode(bytes));
    if (value && typeof value === "object" && !Array.isArray(value)) return value;
  } catch {
    // Falls through to the error below.
  }
  throw new JwsError(`jws: bad ${what}`);
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
