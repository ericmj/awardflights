// Round-trip test for the macOS v10 cookie decryption in extract-vivaldi-cookies.mjs.
// Reproduces Chromium's encryption (PBKDF2 -> AES-128-CBC, IV = 16 spaces, "v10"
// prefix, optional 32-byte SHA-256(host_key) domain hash), then confirms
// decryptValue inverts it. No keychain and no real cookies are touched.
//
// Run: node decrypt.test.mjs
import { decryptValue } from "./extract-vivaldi-cookies.mjs";
import { pbkdf2Sync, createCipheriv, createHash } from "node:crypto";
import assert from "node:assert";

const aesKey = pbkdf2Sync("Zx9QwErTy1234567", "saltysalt", 1003, 16, "sha1");
const iv = Buffer.alloc(16, 0x20);

const pkcs7 = (buf) => {
  const pad = 16 - (buf.length % 16);
  return Buffer.concat([buf, Buffer.alloc(pad, pad)]);
};

function encrypt(value, hostKey, withDomainHash) {
  let plain = Buffer.from(value, "utf8");
  if (withDomainHash) {
    plain = Buffer.concat([createHash("sha256").update(hostKey).digest(), plain]);
  }
  const c = createCipheriv("aes-128-cbc", aesKey, iv);
  c.setAutoPadding(false);
  const ct = Buffer.concat([c.update(pkcs7(plain)), c.final()]);
  return Buffer.concat([Buffer.from("v10"), ct]).toString("hex");
}

const cases = [
  { v: "eyJhbGciOiJI.PAYLOAD.SIG", host: ".sas.se", hash: false },
  { v: "eyJhbGciOiJI.PAYLOAD.SIG", host: ".sas.se", hash: true },
  { v: "short", host: "www.sas.se", hash: true },
  { v: "a".repeat(41), host: ".sas.se", hash: true },
  { v: "", host: ".sas.se", hash: true },
];

for (const [i, c] of cases.entries()) {
  const { value, ok, note } = decryptValue(encrypt(c.v, c.host, c.hash), aesKey, c.host);
  assert(ok, `case ${i} not ok: ${note}`);
  assert.strictEqual(value, c.v, `case ${i} value mismatch: got ${JSON.stringify(value)}`);
}

const wrongKey = pbkdf2Sync("different-password", "saltysalt", 1003, 16, "sha1");
assert(
  decryptValue(encrypt("secret", ".sas.se", true), wrongKey, ".sas.se").ok === false,
  "wrong key should fail, not silently return garbage",
);

const plainHex = Buffer.from("plainvalue", "utf8").toString("hex");
const plain = decryptValue(plainHex, aesKey, ".sas.se");
assert(plain.ok && plain.value === "plainvalue", "unencrypted passthrough failed");

console.log(`all ${cases.length + 2} decryption assertions passed`);
