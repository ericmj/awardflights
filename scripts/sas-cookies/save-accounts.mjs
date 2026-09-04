// Save SAS credentials for several accounts. For each account, this opens a
// dedicated browser profile to sas.se and waits for YOU to finish logging in
// (the one step I can't do — I won't touch passwords). Then the script runs the
// points search itself to mint LOGIN_AUTH, VERIFIES the credential by calling
// the award-api from inside the logged-in window, and only reports success on a
// 200. A bad capture is retried while the window is open, so a dud never reaches
// you. Verified cookies are written to credentials.csv under the account name.
//
// Run: node save-accounts.mjs ericmj5@hex.pm ericmj6@hex.pm ...
// Sessions persist in the profile, so an account logged in on a prior run
// usually restores without logging in again.

import { chromium } from "playwright";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { mkdirSync } from "node:fs";
import { writeCredential } from "./credentials-csv.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const CRED = resolve(__dirname, "..", "..", "credentials.csv");
const PROFILES = resolve(__dirname, ".sas-profiles");

const accounts = process.argv.slice(2);
if (accounts.length === 0) {
  console.error("usage: node save-accounts.mjs <name1> <name2> ...");
  process.exit(1);
}

const DEEPLINK =
  "https://www.sas.se/book/flights/?search=RT_GOT-ORD-20261015-20261022_a1c0i0y0" +
  "&view=upsell&bookingFlow=points&sortBy=rec,rec&filterBy=all,all";
const AWARD_URL =
  "https://www.sas.se/award-api/flights?origin=GOT&destination=ORD&outboundDate=2026-10-15" +
  "&tripType=one-way&selectedCouponCodes=&adults=1&children=0&infants=0&youths=0";
const SID = "fbff2a07-057a-4d7b-ad56-5279c28137fe";
const LOGIN_WAIT = Number(process.env.LOGIN_WAIT || 600);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const summary = [];

async function isLoggedIn(ctx, page) {
  if (!/^https:\/\/www\.sas\.se\//.test(page.url())) return false;
  const jar = await ctx.cookies();
  return jar.some((c) => c.name === "__newwebssosession" && c.value);
}

// Call the award-api from inside the logged-in page; returns HTTP status.
async function awardStatus(page) {
  return await page.evaluate(
    async ({ url, sid }) => {
      try {
        const r = await fetch(url, {
          credentials: "include",
          headers: {
            channel: "WEB", language: "sv", locale: "sv-se", pos: "SE",
            accept: "application/json", "sas-user-session-id": sid,
          },
        });
        return r.status;
      } catch (e) {
        return -1;
      }
    },
    { url: AWARD_URL, sid: SID },
  );
}

for (const name of accounts) {
  const profileDir = join(PROFILES, name.replace(/[^A-Za-z0-9._@-]/g, "_"));
  mkdirSync(profileDir, { recursive: true });
  console.log(`\n=== ${name} ===`);

  const ctx = await chromium.launchPersistentContext(profileDir, {
    headless: false,
    channel: "chrome",
    viewport: null,
  });
  await ctx.addInitScript(() => {
    Object.defineProperty(navigator, "webdriver", { get: () => undefined });
  });
  const page = ctx.pages()[0] || (await ctx.newPage());
  await page.goto("https://www.sas.se/", { waitUntil: "domcontentloaded" }).catch(() => {});

  console.log(`[${name}] Waiting for login (nothing to do if the session restored)...`);
  const deadline = Date.now() + LOGIN_WAIT * 1000;
  let loggedIn = false;
  while (Date.now() < deadline) {
    if (await isLoggedIn(ctx, page)) { loggedIn = true; break; }
    await sleep(3000);
  }
  if (!loggedIn) {
    console.log(`SKIP ${name}: no login detected`);
    summary.push(`${name}: SKIPPED (no login)`);
    await ctx.close();
    continue;
  }

  // Search to mint LOGIN_AUTH, then verify via the award-api. Retry until 200.
  console.log(`[${name}] logged in — search + verify...`);
  let status = 0;
  for (let attempt = 0; attempt < 3 && status !== 200; attempt++) {
    await page.goto(DEEPLINK, { waitUntil: "domcontentloaded" }).catch(() => {});
    for (let i = 0; i < 40; i++) {
      const jar = await ctx.cookies();
      if (jar.some((c) => c.name === "LOGIN_AUTH" && c.value)) break;
      await sleep(1000);
    }
    status = await awardStatus(page);
    if (status !== 200) await sleep(4000);
  }

  const jar = await ctx.cookies("https://www.sas.se");
  const cookieStr = jar.map((c) => `${c.name}=${c.value}`).join("; ");

  if (status === 200) {
    writeCredential(CRED, ["award", "offers"], name, cookieStr);
    console.log(`SAVED+VERIFIED ${name}: award-api 200, ${jar.length} cookies`);
    summary.push(`${name}: VERIFIED (award 200)`);
  } else {
    console.log(`FAILED ${name}: award-api returned ${status} — not saved`);
    summary.push(`${name}: FAILED (award ${status}), not saved`);
  }
  await ctx.close();
}

console.log("\n=== summary ===");
for (const line of summary) console.log(line);
