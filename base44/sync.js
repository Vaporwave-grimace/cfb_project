// sync.js — ESM
// Reads today's CFB CSV exports and upserts into Base44 entities:
//   BET_HISTORY_CFB_YYYYMMDD.csv    → CFBBet
//   MASTER_TICKET_CFB_YYYYMMDD.csv  → CFBGame
//
// Usage:
//   node sync.js              # sync today's files
//   node sync.js 20260906     # sync a specific date (YYYYMMDD)
//
// Required credentials.json keys:
//   base44_token  — same token used by mlb_NRFI_YRFI/scripts/credentials.json

import { createClient } from '@base44/sdk';
import { readFileSync, readdirSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { parse } from 'csv-parse/sync';

const __dirname   = dirname(fileURLToPath(import.meta.url));
const APP_ID      = '69ce95e89103a042f4ca8797';
const EXPORTS_DIR = join(__dirname, '..', 'exports');
const CREDS_PATH  = join(__dirname, '..', 'credentials.json');

// ── Helpers ───────────────────────────────────────────────────────────────────

function loadCreds() {
  if (!existsSync(CREDS_PATH))
    throw new Error(`credentials.json not found at ${CREDS_PATH}`);
  const raw = JSON.parse(readFileSync(CREDS_PATH, 'utf8'));
  if (!raw.base44_token)
    throw new Error('Set base44_token in credentials.json (same token as mlb_NRFI_YRFI)');
  return { token: raw.base44_token };
}

function findCSV(prefix, dateStr) {
  if (!existsSync(EXPORTS_DIR)) {
    console.warn(`[sync] exports/ directory not found at ${EXPORTS_DIR}`);
    return null;
  }
  const files = readdirSync(EXPORTS_DIR)
    .filter(f => f.startsWith(prefix) && f.endsWith('.csv'))
    .sort().reverse();

  if (dateStr) {
    const target = `${prefix}${dateStr}.csv`;
    const found  = files.find(f => f === target);
    if (!found) { console.warn(`[sync] No file: ${target}`); return null; }
    return join(EXPORTS_DIR, found);
  }
  return files.length > 0 ? join(EXPORTS_DIR, files[0]) : null;
}

function readCSV(filePath) {
  return parse(readFileSync(filePath, 'utf8'), {
    columns: true, skip_empty_lines: true, cast: true,
  });
}

// Coerce "NA" / "NaN" / "" → null; force string fields to string
function sanitize(row, stringFields = []) {
  const out = {};
  for (const [k, v] of Object.entries(row)) {
    if (v === 'NA' || v === 'NaN' || v === '') {
      out[k] = null;
    } else if (stringFields.includes(k)) {
      out[k] = String(v);
    } else {
      out[k] = v;
    }
  }
  return out;
}

// Delete all records for this game_date+sport, then create fresh.
// sport filter prevents MLB records from being wiped during Sep overlap.
async function replaceByDate(entity, entityName, rows, gameDate, stringFields = [], sport = 'CFB') {
  const existing = await entity.list();
  const toDelete = existing.filter(r => r.game_date === gameDate && r.sport === sport);
  await Promise.all(toDelete.map(r => entity.delete(r.id)));

  let created = 0;
  for (const row of rows) {
    try {
      await entity.create(sanitize(row, stringFields));
      created++;
    } catch (e) {
      console.error(`[sync] ${entityName} create failed (${row.game_id}): ${e.message}`);
    }
  }
  console.log(`[sync] ${entityName}: deleted ${toDelete.length} old, created ${created} new`);
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  // Accept YYYYMMDD arg (from R system() call: "node sync.js 20260906")
  const dateArg = process.argv[2] || null;
  console.log(`[sync] Starting CFB Base44 sync — ${dateArg || 'latest'}`);

  const { token } = loadCreds();
  const base44 = createClient({ appId: APP_ID });
  base44.auth.setToken(token);
  console.log(`[sync] Token set | App: ${APP_ID}`);

  // BetHistory ← BET_HISTORY_CFB (same entity as MLB, sport="CFB" prevents collision)
  const betPath = findCSV('BET_HISTORY_CFB_', dateArg);
  if (betPath) {
    console.log(`[sync] Reading ${betPath.split(/[\\/]/).pop()}`);
    const rows = readCSV(betPath);
    if (rows.length > 0) {
      await replaceByDate(
        base44.entities.BetHistory, 'BetHistory', rows, rows[0]?.game_date,
        ['pick_label', 'boost_flags'], 'CFB'
      );
    } else {
      console.log('[sync] BetHistory (CFB): 0 rows — skipping.');
    }
  }

  // Game ← MASTER_TICKET_CFB (same entity as MLB, sport="CFB" prevents collision)
  const ticketPath = findCSV('MASTER_TICKET_CFB_', dateArg);
  if (ticketPath) {
    console.log(`[sync] Reading ${ticketPath.split(/[\\/]/).pop()}`);
    const rows = readCSV(ticketPath);
    if (rows.length > 0) {
      await replaceByDate(
        base44.entities.Game, 'Game', rows, rows[0]?.game_date,
        [], 'CFB'
      );
    } else {
      console.log('[sync] Game (CFB): 0 rows — skipping.');
    }
  }

  console.log('[sync] CFB Base44 sync complete.');
}

main().catch(e => { console.error('[sync] Fatal:', e.message); process.exit(1); });
