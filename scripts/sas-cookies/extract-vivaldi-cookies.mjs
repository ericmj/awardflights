#!/usr/bin/env node
// Extract SAS session cookies directly from Vivaldi's on-disk cookie store and
// write them into the awardflights scanner's credentials.csv. Works while
// Vivaldi is running; no browser automation, no manual copy-paste.
//
// How it works on macOS: Chromium browsers encrypt cookie values with AES-128-CBC
// under a key kept in the login keychain (here "Vivaldi Safe Storage"). This reads
// that key (macOS prompts you to allow it), copies the cookie SQLite so it does
// not fight the running browser for the file, pulls the sas.se rows via the system
// `sqlite3`, and decrypts them. Cookie values are written to credentials.csv only,
// never printed.

import { execFileSync } from "node:child_process";
import { pbkdf2Sync, createDecipheriv, createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { fileURLToPath } from "node:url";
import { realpathSync } from "node:fs";
import { dirname, resolve, join } from "node:path";
import { writeCredential } from "./credentials-csv.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "..", "..");

const HELP = `Extract SAS cookies from Vivaldi's cookie store into credentials.csv.

Usage: node extract-vivaldi-cookies.mjs [options]

  --name <str>            Credential name (CSV "name" column). Default "SAS EuroBonus".
  --file <path>           credentials.csv path. Default <repo>/credentials.csv.
  --sources <a,b>         Sources to write. Default "award,offers".
  --profile <path>        Vivaldi user-data dir.
                          Default ~/Library/Application Support/Vivaldi.
  --cookie-db <path>      Cookie SQLite. Default <profile>/Default/Cookies.
  --host <substr>         host_key match. Default "sas.se".
  --keychain-service <s>  Keychain service. Default "Vivaldi Safe Storage".
  --keychain-account <s>  Keychain account. Default "Vivaldi".
  --list                  List every cookie's domain and name (no values, no
                          keychain, no write). Optionally filtered by --grep.
  --grep <substr>         With --list, only names matching this substring
                          (case-insensitive).
  --help                  Show this help.

macOS will prompt you to allow reading the keychain key the first time.`;

function parseArgs(argv) {
  const opts = {
    name: process.env.SAS_CREDENTIAL_NAME || "SAS EuroBonus",
    file: process.env.AWARDFLIGHTS_CREDENTIALS || resolve(REPO_ROOT, "credentials.csv"),
    sources: ["award", "offers"],
    profile: resolve(homedir(), "Library/Application Support/Vivaldi"),
    cookieDb: null,
    host: "sas.se",
    keychainService: "Vivaldi Safe Storage",
    keychainAccount: "Vivaldi",
    authCookies: ["__session"],
    list: false,
    grep: null,
  };
  for (let i = 2; i < argv.length; i++) {
    const [key, inlineVal] = argv[i].split(/=(.*)/s);
    const next = () => inlineVal ?? argv[++i];
    switch (key) {
      case "--name": opts.name = next(); break;
      case "--file": opts.file = resolve(next()); break;
      case "--sources": opts.sources = next().split(",").map((s) => s.trim()).filter(Boolean); break;
      case "--profile": opts.profile = resolve(next()); break;
      case "--cookie-db": opts.cookieDb = resolve(next()); break;
      case "--host": opts.host = next(); break;
      case "--keychain-service": opts.keychainService = next(); break;
      case "--keychain-account": opts.keychainAccount = next(); break;
      case "--list": opts.list = true; break;
      case "--grep": opts.grep = next(); break;
      case "--help": console.log(HELP); process.exit(0); break;
      default:
        console.error(`Unknown argument: ${key}`);
        console.log(HELP);
        process.exit(1);
    }
  }
  if (!opts.cookieDb) {
    const network = join(opts.profile, "Default", "Network", "Cookies");
    const legacy = join(opts.profile, "Default", "Cookies");
    opts.cookieDb = existsSync(network) ? network : legacy;
  }
  return opts;
}

function keychainPassword(service, account) {
  try {
    return execFileSync("security", ["find-generic-password", "-w", "-s", service, "-a", account], {
      encoding: "utf8",
    }).replace(/\n$/, "");
  } catch {
    // Retry without pinning the account, in case it differs from the app name.
    return execFileSync("security", ["find-generic-password", "-w", "-s", service], {
      encoding: "utf8",
    }).replace(/\n$/, "");
  }
}

function readRows(dbPath, host) {
  const tmp = mkdtempSync(join(tmpdir(), "vivaldi-cookies-"));
  try {
    const copy = join(tmp, "Cookies");
    copyFileSync(dbPath, copy);
    for (const suffix of ["-wal", "-shm"]) {
      if (existsSync(dbPath + suffix)) copyFileSync(dbPath + suffix, copy + suffix);
    }
    const safeHost = host.replace(/[^A-Za-z0-9.\-_]/g, "");
    const sql =
      `SELECT host_key, name, hex(encrypted_value) AS ev, is_httponly ` +
      `FROM cookies WHERE host_key LIKE '%${safeHost}%';`;
    const out = execFileSync("sqlite3", ["-json", copy, sql], { encoding: "utf8" }).trim();
    return out ? JSON.parse(out) : [];
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

// Names-only listing across all domains. No decryption, no keychain.
function readNames(dbPath) {
  const tmp = mkdtempSync(join(tmpdir(), "vivaldi-cookies-"));
  try {
    const copy = join(tmp, "Cookies");
    copyFileSync(dbPath, copy);
    for (const suffix of ["-wal", "-shm"]) {
      if (existsSync(dbPath + suffix)) copyFileSync(dbPath + suffix, copy + suffix);
    }
    const sql = "SELECT host_key, name FROM cookies ORDER BY host_key, name;";
    const out = execFileSync("sqlite3", ["-json", copy, sql], { encoding: "utf8" }).trim();
    return out ? JSON.parse(out) : [];
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

// macOS v10 cookie value: "v10" prefix + AES-128-CBC (IV = 16 spaces). After
// decrypt, recent Chromium prepends a 32-byte SHA-256(host_key) domain hash.
export function decryptValue(hex, aesKey, hostKey) {
  const buf = Buffer.from(hex, "hex");
  const prefix = buf.subarray(0, 3).toString("latin1");
  if (prefix !== "v10" && prefix !== "v11") {
    return { value: buf.toString("utf8"), ok: true, note: "unencrypted" };
  }
  const iv = Buffer.alloc(16, 0x20);
  const decipher = createDecipheriv("aes-128-cbc", aesKey, iv);
  decipher.setAutoPadding(false);
  let dec;
  try {
    dec = Buffer.concat([decipher.update(buf.subarray(3)), decipher.final()]);
  } catch (e) {
    return { value: "", ok: false, note: `decrypt failed: ${e.message}` };
  }
  const pad = dec[dec.length - 1];
  if (pad >= 1 && pad <= 16) dec = dec.subarray(0, dec.length - pad);
  else return { value: "", ok: false, note: "bad padding (wrong key?)" };

  const domainHash = createHash("sha256").update(hostKey).digest();
  if (dec.length >= 32 && dec.subarray(0, 32).equals(domainHash)) dec = dec.subarray(32);
  return { value: dec.toString("utf8"), ok: true, note: "" };
}

function main() {
  const opts = parseArgs(process.argv);

  if (!existsSync(opts.cookieDb)) {
    console.error(`Cookie store not found: ${opts.cookieDb}`);
    console.error("Pass --cookie-db or --profile with your Vivaldi path.");
    process.exit(1);
  }

  if (opts.list) {
    let rows = readNames(opts.cookieDb);
    if (opts.grep) {
      const needle = opts.grep.toLowerCase();
      rows = rows.filter((r) => r.name.toLowerCase().includes(needle));
    }
    const width = rows.reduce((w, r) => Math.max(w, r.host_key.length), 0);
    for (const r of rows) console.log(`${r.host_key.padEnd(width)}  ${r.name}`);
    console.log(`\n${rows.length} cookie(s)${opts.grep ? ` matching "${opts.grep}"` : ""}.`);
    return;
  }

  console.log(`Cookie store: ${opts.cookieDb}`);
  console.log(`Credentials:  ${opts.file}`);
  console.log(`Name:         ${opts.name}`);
  console.log(`Sources:      ${opts.sources.join(", ")}`);
  console.log("");
  console.log(`Reading keychain key "${opts.keychainService}" (macOS may prompt to allow)...`);

  let password;
  try {
    password = keychainPassword(opts.keychainService, opts.keychainAccount);
  } catch (e) {
    console.error(`Could not read keychain key: ${e.message}`);
    console.error("If prompted by macOS, choose Allow. Check the service name with --keychain-service.");
    process.exit(1);
  }
  const aesKey = pbkdf2Sync(password, "saltysalt", 1003, 16, "sha1");

  const rows = readRows(opts.cookieDb, opts.host);
  if (rows.length === 0) {
    console.error(`No cookies for host matching "${opts.host}". Are you logged in to SAS in Vivaldi?`);
    process.exit(1);
  }

  // Dedupe by cookie name, keeping the most specific host_key.
  const byName = new Map();
  const failures = [];
  for (const r of rows) {
    const { value, ok, note } = decryptValue(r.ev, aesKey, r.host_key);
    if (!ok) {
      failures.push(`${r.name} (${note})`);
      continue;
    }
    const existing = byName.get(r.name);
    if (!existing || r.host_key.length > existing.host_key.length) {
      byName.set(r.name, { name: r.name, value, host_key: r.host_key });
    }
  }

  const cookies = [...byName.values()];
  if (cookies.length === 0) {
    console.error("Every cookie failed to decrypt. The keychain key or cookie format did not match.");
    if (failures.length) console.error("  " + failures.join("\n  "));
    process.exit(1);
  }

  const header = cookies.map((c) => `${c.name}=${c.value}`).join("; ");
  writeCredential(opts.file, opts.sources, opts.name, header);

  const names = cookies.map((c) => c.name);
  console.log("");
  console.log(`Decrypted ${cookies.length} cookies: ${names.join(", ")}`);
  for (const expected of opts.authCookies) {
    console.log(`  ${names.includes(expected) ? "present" : "MISSING"}: ${expected}`);
  }
  if (failures.length) console.warn(`\n${failures.length} cookie(s) failed to decrypt: ${failures.join(", ")}`);
  if (!opts.authCookies.some((n) => names.includes(n))) {
    console.warn("\nWarning: none of the expected auth cookies were present.");
    console.warn("Check the names above; if the live name differs, pass it to the scanner accordingly.");
  }
  console.log(`\nWrote ${opts.sources.length} row(s) to ${opts.file} under name "${opts.name}".`);
  console.log("Cookie values were written to disk only, not printed here.");
}

const isMain =
  process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) main();
