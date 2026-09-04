#!/usr/bin/env node
// Capture SAS session cookies from a browser profile and write them into the
// awardflights scanner's credentials.csv.
//
// A real browser is launched against a dedicated profile directory. You log in
// to sas.se by hand once; the session persists in that profile, so later runs
// reuse it and refresh the stored cookies without another login. HttpOnly
// cookies (LOGIN_AUTH, __session) are unreadable from page JavaScript but are
// available from the browser context, which is what this reads.

import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { homedir } from "node:os";
import { readFileSync, existsSync, mkdirSync, realpathSync } from "node:fs";
import { parseCsv, upsert, writeCsv } from "./credentials-csv.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "..", "..");

// Browser presets. "dedicated" browsers launch a throwaway profile you log into
// once (default flow). "reuse: true" browsers point at your real profile and
// read the session already there, so no login, but the browser must be quit
// first because Chromium holds an exclusive lock on its profile while running.
const BROWSERS = {
  chrome: {
    channel: "chrome",
    defaultProfile: resolve(__dirname, ".chrome-profile"),
  },
  chromium: {
    defaultProfile: resolve(__dirname, ".chrome-profile"),
  },
  vivaldi: {
    executablePath: "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi",
    defaultProfile: resolve(homedir(), "Library/Application Support/Vivaldi"),
    reuse: true,
  },
  brave: {
    executablePath: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    defaultProfile: resolve(homedir(), "Library/Application Support/BraveSoftware/Brave-Browser"),
    reuse: true,
  },
  edge: {
    channel: "msedge",
    defaultProfile: resolve(homedir(), "Library/Application Support/Microsoft Edge"),
    reuse: true,
  },
};

function parseArgs(argv) {
  const opts = {
    name: process.env.SAS_CREDENTIAL_NAME || "SAS EuroBonus",
    file: process.env.AWARDFLIGHTS_CREDENTIALS || resolve(REPO_ROOT, "credentials.csv"),
    sources: ["award", "offers"],
    browser: "chrome",
    profile: null,
    executablePath: null,
    authCookies: ["__session"],
    loginTimeout: 300,
    url: "https://www.sas.se/",
    cookieUrl: "https://www.sas.se",
  };
  for (let i = 2; i < argv.length; i++) {
    const [key, inlineVal] = argv[i].split(/=(.*)/s);
    const next = () => inlineVal ?? argv[++i];
    switch (key) {
      case "--name": opts.name = next(); break;
      case "--file": opts.file = resolve(next()); break;
      case "--sources": opts.sources = next().split(",").map((s) => s.trim()).filter(Boolean); break;
      case "--browser": opts.browser = next(); break;
      case "--profile": opts.profile = resolve(next()); break;
      case "--executable-path": opts.executablePath = resolve(next()); break;
      case "--auth-cookie": opts.authCookies = next().split(",").map((s) => s.trim()).filter(Boolean); break;
      case "--login-timeout": opts.loginTimeout = Number(next()); break;
      case "--help":
        console.log(HELP);
        process.exit(0);
        break;
      default:
        console.error(`Unknown argument: ${key}`);
        console.log(HELP);
        process.exit(1);
    }
  }

  const preset = BROWSERS[opts.browser];
  if (!preset) {
    console.error(`Unknown browser "${opts.browser}". Known: ${Object.keys(BROWSERS).join(", ")}.`);
    process.exit(1);
  }
  opts.preset = preset;
  if (opts.profile === null) opts.profile = preset.defaultProfile;
  if (opts.executablePath === null) opts.executablePath = preset.executablePath ?? null;
  return opts;
}

const HELP = `Capture SAS session cookies into credentials.csv.

Usage: node capture-cookies.mjs [options]

  --name <str>          Credential name (CSV "name" column). Default "SAS EuroBonus".
  --file <path>         credentials.csv path. Default <repo>/credentials.csv.
  --sources <a,b>       Sources to write. Default "award,offers".
  --browser <name>      chrome (default), chromium, vivaldi, brave, edge.
                        vivaldi/brave/edge reuse your real, already-logged-in
                        profile (no login), but that browser must be quit first.
  --profile <path>      Profile / user-data dir. Defaults per browser.
  --executable-path <p> Browser binary. Defaults per browser.
  --auth-cookie <a,b>   Cookie names that signal a logged-in session.
                        Default "__session".
  --login-timeout <s>   Seconds to wait for login before capturing anyway. Default 300.
  --help                Show this help.

chrome opens a dedicated profile you log into once. vivaldi/brave/edge open your
real profile and read the session already there, so quit that browser first.`;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function launchContext(opts) {
  const common = { headless: false, viewport: null };
  const { preset } = opts;

  if (opts.executablePath) {
    if (!existsSync(opts.executablePath)) {
      throw new Error(`Browser binary not found: ${opts.executablePath}`);
    }
    return await chromium.launchPersistentContext(opts.profile, {
      ...common,
      executablePath: opts.executablePath,
      timeout: 45000,
    });
  }
  try {
    return await chromium.launchPersistentContext(opts.profile, {
      ...common,
      ...(preset.channel ? { channel: preset.channel } : {}),
      timeout: 45000,
    });
  } catch (err) {
    console.error(`Could not launch ${opts.browser} (${err.message}); using bundled Chromium.`);
    console.error("If this fails too, run: npx playwright install chromium");
    return await chromium.launchPersistentContext(opts.profile, { ...common, timeout: 45000 });
  }
}

function isProfileLockError(err) {
  const m = String(err && err.message);
  return /ProcessSingleton|SingletonLock|already running|profile.*in use|Failed to create a ProcessSingleton/i.test(m);
}

async function main() {
  const opts = parseArgs(process.argv);
  const reuse = Boolean(opts.preset.reuse);
  // Only create the dir for the dedicated-profile flow; a reuse profile must
  // already exist (creating it would mean the browser isn't really logged in).
  if (!reuse && !existsSync(opts.profile)) mkdirSync(opts.profile, { recursive: true });
  if (reuse && !existsSync(opts.profile)) {
    console.error(`Profile not found: ${opts.profile}`);
    console.error(`Pass --profile with your ${opts.browser} user-data dir.`);
    process.exit(1);
  }

  console.log(`Browser:      ${opts.browser}${reuse ? " (reusing your real profile)" : " (dedicated profile)"}`);
  console.log(`Profile:      ${opts.profile}`);
  console.log(`Credentials:  ${opts.file}`);
  console.log(`Name:         ${opts.name}`);
  console.log(`Sources:      ${opts.sources.join(", ")}`);
  console.log("");

  let context;
  try {
    context = await launchContext(opts);
  } catch (err) {
    if (reuse && isProfileLockError(err)) {
      console.error(`${opts.browser} is still running and holds a lock on its profile.`);
      console.error(`Quit ${opts.browser} completely, then run this again.`);
      process.exit(1);
    }
    throw err;
  }
  const page = context.pages()[0] || (await context.newPage());
  await page.goto(opts.url, { waitUntil: "domcontentloaded" }).catch(() => {});

  if (reuse) {
    console.log("Reading the session already in this profile...");
  } else {
    console.log("Browser open. Log in to sas.se in that window if you are not already.");
  }
  console.log(`Waiting up to ${opts.loginTimeout}s for a session cookie...`);

  const deadline = Date.now() + opts.loginTimeout * 1000;
  let cookies = [];
  let sawAuth = false;
  while (Date.now() < deadline) {
    cookies = await context.cookies(opts.cookieUrl);
    sawAuth = cookies.some((c) => opts.authCookies.includes(c.name) && c.value);
    if (sawAuth) break;
    await sleep(2000);
  }

  cookies = await context.cookies(opts.cookieUrl);
  const names = cookies.map((c) => c.name);
  const cookieHeader = cookies.map((c) => `${c.name}=${c.value}`).join("; ");

  await context.close();

  if (cookies.length === 0) {
    console.error("No cookies found for sas.se. Nothing written.");
    process.exit(1);
  }

  const existing = existsSync(opts.file) ? parseCsv(readFileSync(opts.file, "utf8")) : [];
  writeCsv(opts.file, upsert(existing, opts.sources, opts.name, cookieHeader));

  console.log("");
  console.log(`Captured ${cookies.length} cookies: ${names.join(", ")}`);
  for (const expected of opts.authCookies) {
    console.log(`  ${names.includes(expected) ? "present" : "MISSING"}: ${expected}`);
  }
  if (!sawAuth) {
    console.warn("\nWarning: no expected auth cookie appeared before the timeout.");
    console.warn("The session may not be logged in. Check the cookie names above.");
  }
  console.log(`\nWrote ${opts.sources.length} row(s) to ${opts.file} under name "${opts.name}".`);
  console.log("Cookie values were written to disk only, not printed here.");
}

const isMain =
  process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);

if (isMain) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
