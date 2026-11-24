import { createCipheriv, createDecipheriv, createHash, randomBytes, timingSafeEqual } from 'node:crypto';
const MAX = 10 * 1024 * 1024;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HASH = /^[0-9a-f]{64}$/;
const digest = (b) => createHash('sha256').update(b).digest('hex');
const context = (org, id, keyRef, hash) => {
  if (!UUID.test(org) || !UUID.test(id) || typeof keyRef !== 'string' || !/^[a-zA-Z0-9._:-]{8,250}$/.test(keyRef) || !HASH.test(hash)) throw new Error('Invalid envelope context');
  return Buffer.from(JSON.stringify(['nforce-2316-v1', org.toLowerCase(), id.toLowerCase(), keyRef, hash]));
};
function checkKey(key) {
  if (!Buffer.isBuffer(key) || key.length !== 32) throw new Error('Invalid encryption key');
}
export function seal2316({org, id, keyRef, key, plaintext, expectedSha256}) {
  checkKey(key);
  if (!Buffer.isBuffer(plaintext) || plaintext.length < 1 || plaintext.length > MAX-29) throw new Error('Invalid document size');
  const aad = context(org,id,keyRef,expectedSha256);
  if (!timingSafeEqual(Buffer.from(digest(plaintext),'hex'), Buffer.from(expectedSha256,'hex'))) throw new Error('Document hash mismatch');
  const nonce = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm',key,nonce,{authTagLength:16});
  cipher.setAAD(aad);
  const body = Buffer.concat([cipher.update(plaintext),cipher.final()]);
  const bytes = Buffer.concat([Buffer.from([1]),nonce,cipher.getAuthTag(),body]);
  return { bytes, sha256:digest(bytes), plaintextSha256:expectedSha256, keyReference:keyRef };
}
export function open2316({org,id,keyRef,key,bytes,expectedSha256,ciphertextSha256}) {
  checkKey(key);
  if (!Buffer.isBuffer(bytes) || bytes.length<30 || bytes.length>MAX || bytes[0]!==1 || !HASH.test(ciphertextSha256)) throw new Error('Invalid envelope');
  if (!timingSafeEqual(Buffer.from(digest(bytes),'hex'),Buffer.from(ciphertextSha256,'hex'))) throw new Error('Envelope hash mismatch');
  const decipher = createDecipheriv('aes-256-gcm',key,bytes.subarray(1,13),{authTagLength:16});
  decipher.setAAD(context(org,id,keyRef,expectedSha256));
  decipher.setAuthTag(bytes.subarray(13,29));
  const plain = Buffer.concat([decipher.update(bytes.subarray(29)),decipher.final()]);
  if (!timingSafeEqual(Buffer.from(digest(plain),'hex'),Buffer.from(expectedSha256,'hex'))) throw new Error('Document hash mismatch');
  return plain;
}
