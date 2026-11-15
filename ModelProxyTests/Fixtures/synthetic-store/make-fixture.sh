#!/bin/bash
# Regenerates the synthetic zcode credential-store fixtures used by CredentialStoreTests.
#
# Format mirrors the real scratch store (zgate docs/signing-notes.md):
#   credentials.json values: enc:v2:env:<24-hex fp>:<iv>.<tag>.<ct>  (unpadded base64url, AES-256-GCM)
#   key = sha256(secret.txt bytes); fp = sha256(key).hex[0..<24]
#
# Everything here is SYNTHETIC — no real token bytes ever appear. The generated
# files are committed so the test suite never needs node. IVs are derived
# per-field (sha256 of the field name) instead of random so regeneration is
# deterministic; acceptable for test data, never for real secrets.
set -euo pipefail
cd "$(dirname "$0")"

node <<'EOF'
const crypto = require('crypto');
const fs = require('fs');

const secret = 'zgate-synthetic-secret-2c9f4a71';
const key = crypto.createHash('sha256').update(secret, 'utf8').digest();
const fp = crypto.createHash('sha256').update(key).digest('hex').slice(0, 24);
const b64u = (buf) => buf.toString('base64url');

function seal(field, plaintext) {
  const iv = crypto.createHash('sha256').update('iv:' + field).digest().subarray(0, 12);
  const c = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ct = Buffer.concat([c.update(plaintext, 'utf8'), c.final()]);
  const tag = c.getAuthTag();
  return `enc:v2:env:${fp}:${b64u(iv)}.${b64u(tag)}.${b64u(ct)}`;
}

// Fake 3-part JWT with synthetic claims and a known exp.
function fakeJwt(payloadObject) {
  const header = b64u(Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' }), 'utf8'));
  let seg = '';
  // Ensure the payload segment length is NOT a multiple of 4 — i.e. unpadded
  // base64url that a naive Data(base64Encoded:) decode would reject. This pins
  // the padding-bug regression CredentialStoreTests checks for.
  do {
    seg = b64u(Buffer.from(JSON.stringify(payloadObject), 'utf8'));
    if (seg.length % 4 === 0) payloadObject.pad = (payloadObject.pad || '') + 'x';
  } while (seg.length % 4 === 0);
  const sig = crypto.createHash('sha256').update('sig:' + seg).digest('base64url');
  return `${header}.${seg}.${sig}`;
}

const accessTokenJwt = fakeJwt({ iss: 'user-service', token_type: 'access_token', iat: 1763000000, exp: 1763003600 });
const identityJwt = fakeJwt({ user_id: 'synthetic-user', token_version: 1, sub: 'synthetic-sub', iat: 1763000000 }); // no exp, like the real one

// Real store shape (live-verified 2026-11-15): the field NAME carries the
// percent-encoded identity array; the VALUE is the location OBJECT
// {"organizationId","projectId","apiKeyId"} that the mint call targets.
const locationArray = JSON.stringify(['https://api.z.ai', 'zai', '11111111-2222-3333-4444-555555555555', null, 1, 'default']);
const locationObject = JSON.stringify({
  organizationId: '11111111-2222-3333-4444-555555555555',
  projectId: '22222222-3333-4444-5555-666666666666',
  apiKeyId: '89abcdef89abcdef89abcdef89abcdef',
});
const locationKey = 'project-key-location:v1:' + encodeURIComponent(locationArray);

const store = {
  'oauth:active_provider': seal('oauth:active_provider', 'zai'),
  'oauth:zai:access_token': seal('oauth:zai:access_token', accessTokenJwt),
  'zcodejwttoken': seal('zcodejwttoken', identityJwt),
  [locationKey]: seal(locationKey, locationObject),
};

fs.writeFileSync('credentials.json', JSON.stringify(store, null, 2) + '\n');
fs.writeFileSync('secret.txt', secret, 'utf8'); // exact bytes, no trailing newline
console.log('synthetic store written: 4 fields, fingerprint ' + fp);
EOF
