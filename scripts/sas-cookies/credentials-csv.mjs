// Read/write the awardflights scanner's credentials.csv, matching the format in
// Awardflights.CredentialStore: a "source,name,value" header plus rows where
// value is the last column and may itself contain commas.
import { readFileSync, writeFileSync, chmodSync, existsSync } from "node:fs";

export function parseCsv(text) {
  const rows = [];
  const lines = text.split("\n").map((l) => l.trim()).filter(Boolean);
  for (const line of lines.slice(1)) {
    const i1 = line.indexOf(",");
    const i2 = line.indexOf(",", i1 + 1);
    if (i1 < 0 || i2 < 0) continue;
    const source = line.slice(0, i1);
    if (source !== "award" && source !== "offers") continue;
    rows.push({ source, name: line.slice(i1 + 1, i2), value: line.slice(i2 + 1) });
  }
  return rows;
}

export const sanitizeName = (s) => (s ?? "").replace(/[\r\n,]+/g, "").trim();
export const sanitizeValue = (s) => (s ?? "").replace(/[\r\n]+/g, "");

export function writeCsv(file, rows) {
  const header = "source,name,value";
  const lines = rows.map((r) => [r.source, r.name, r.value].join(","));
  writeFileSync(file, [header, ...lines].join("\n") + "\n", { mode: 0o600 });
  chmodSync(file, 0o600);
}

// Replace the row for each (source, name) we captured, leave all others intact.
export function upsert(existing, sources, name, value) {
  const cleanName = sanitizeName(name);
  const cleanValue = sanitizeValue(value);
  const kept = existing.filter(
    (r) => !(sources.includes(r.source) && r.name === cleanName),
  );
  const added = sources.map((source) => ({ source, name: cleanName, value: cleanValue }));
  return [...kept, ...added];
}

// Convenience: load file (or empty), upsert, write back.
export function writeCredential(file, sources, name, value) {
  const existing = existsSync(file) ? parseCsv(readFileSync(file, "utf8")) : [];
  writeCsv(file, upsert(existing, sources, name, value));
}
