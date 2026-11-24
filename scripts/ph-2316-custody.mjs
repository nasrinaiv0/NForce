// Node-only candidate. Never import into the Expo/browser bundle.
// Key material is supplied by a future approved secret/key service.
import { createCipheriv, createDecipheriv, createHash, randomBytes, timingSafeEqual } from 'node:crypto';
const MAX = 10 * 1024 * 1024 - 28;
const digest = b => createHash('sha256').update(b).digest('hex');
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function aad(context) {
  const { organizationId, employeeId, importId, plaintextSha256, keyReference } = context ?? {};
  if (![organizationId, employeeId, importId].every(x => typeof x === 'string' && uuid.test(x))
    || typeof plaintextSha256 !== 'string' || !/^[0-9a-f]{64}$/.test(plaintextSha256)
    || typeof keyReference !== 'string' || keyReference.trim().length < 8 || keyReference.length > 200) {
    throw new Error('Invalid custody context');
  }
  return Buffer.from(JSON.stringify(['nforce-2316-AES-256-GCM-v1', organizationId.toLowerCase(), employeeId.toLowerCase(), importId.toLowerCase(), plaintextSha256, keyReference]), 'utf8');
}
function requireKey(key) {
  if (!Buffer.isBuffer(key) || key.length !== 32) throw new Error('Invalid custody key');
}
function isPdf(bytes) {
  return Buffer.isBuffer(bytes) && bytes.length >= 5 && bytes.length <= MAX && bytes.subarray(0, 5).equals(Buffer.from('%PDF-'));
}
function hashMatches(bytes, expected) {
  return typeof expected === 'string' && /^[0-9a-f]{64}$/.test(expected)
    && timingSafeEqual(Buffer.from(digest(bytes), 'hex'), Buffer.from(expected, 'hex'));
}
export function seal2316(pdf, key, context) {
  requireKey(key);
  const associated = aad(context);
  if (!isPdf(pdf) || !hashMatches(pdf, context.plaintextSha256)) throw new Error('Invalid source document');
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, iv, { authTagLength: 16 });
  cipher.setAAD(associated);
  const encrypted = Buffer.concat([cipher.update(pdf), cipher.final()]);
  const envelope = Buffer.concat([iv, cipher.getAuthTag(), encrypted]);
  return { envelope, ciphertextSha256: digest(envelope), envelopeVersion: 'AES-256-GCM-v1' };
}
export function open2316(envelope, key, context, ciphertextSha256) {
  requireKey(key);
  const associated = aad(context);
  if (!Buffer.isBuffer(envelope) || envelope.length < 33 || envelope.length > MAX + 28 || !hashMatches(envelope, ciphertextSha256))
    throw new Error('Invalid custody envelope');
  try {
    const decipher = createDecipheriv('aes-256-gcm', key, envelope.subarray(0, 12), { authTagLength: 16 });
    decipher.setAAD(associated);
    decipher.setAuthTag(envelope.subarray(12, 28));
    const pdf = Buffer.concat([decipher.update(envelope.subarray(28)), decipher.final()]);
    if (!isPdf(pdf) || !hashMatches(pdf, context.plaintextSha256)) throw new Error('Invalid source');
    return pdf;
  } catch { throw new Error('Custody authentication failed'); }
}
