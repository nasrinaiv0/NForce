import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { seal2316, open2316 } from './ph-2316-custody.mjs';
const hash = b => createHash('sha256').update(b).digest('hex');
const pdf = Buffer.from('%PDF-1.4\\nfictional fixture only\\n%%EOF');
const context = { organizationId:'00000000-0000-0000-0000-000000000001', employeeId:'00000000-0000-0000-0000-000000000002', importId:'00000000-0000-0000-0000-000000000003', plaintextSha256:hash(pdf), keyReference:'test-key-ref' };
test('round trip and randomized nonce',()=> {
 const key=randomBytes(32), a=seal2316(pdf,key,context), b=seal2316(pdf,key,context);
 assert.notDeepEqual(a.envelope,b.envelope); assert.equal(a.ciphertextSha256,hash(a.envelope));
 assert.deepEqual(open2316(a.envelope,key,context,a.ciphertextSha256),pdf);
 assert.equal(a.envelope.includes(pdf),false);
});
test('ciphertext and tag tampering rejected even if hash recomputed',()=> {
 const key=randomBytes(32), a=seal2316(pdf,key,context);
 for(const pos of [0,12,28]){const b=Buffer.from(a.envelope); b[pos]^=1;
 assert.throws(()=>open2316(b,key,context,hash(b)),/authentication failed/);}
 assert.throws(()=>open2316(a.envelope,key,context,'0'.repeat(64)),/Invalid custody envelope/);
});
test('tenant employee import and key binding',()=> {
 const key=randomBytes(32), a=seal2316(pdf,key,context);
 for(const field of ['organizationId','employeeId','importId']) assert.throws(()=>open2316(a.envelope,key,{...context,[field]:'00000000-0000-0000-0000-000000000009'},a.ciphertextSha256));
 assert.throws(()=>open2316(a.envelope,randomBytes(32),context,a.ciphertextSha256));
 assert.throws(()=>open2316(a.envelope,key,{...context,keyReference:'other-key-ref'},a.ciphertextSha256));
});
test('reject malformed sources and keys',()=> {
 const key=randomBytes(32);
 assert.throws(()=>seal2316(pdf,Buffer.alloc(31),context));
 assert.throws(()=>seal2316(pdf,key,{...context,plaintextSha256:'0'.repeat(64)}));
 assert.throws(()=>seal2316(Buffer.from('not a PDF'),key,context));
 assert.throws(()=>seal2316(Buffer.alloc(10*1024*1024),key,context));
});
