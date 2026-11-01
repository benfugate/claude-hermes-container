// Clears every conversation's Claude session on SESSION_RESET_CRON, so each
// period starts fresh instead of resending a long history on every message.
// The UPDATE is the one hermes runs for /reset (src/runtime/session-target.ts):
// hermes reads the row on every message, so the next one opens a new Claude
// session. Long-term memory and transcripts are untouched.
//
//   bun run session-reset.ts         run the schedule (started by entrypoint.sh)
//   bun run session-reset.ts --now   reset once and exit
//
// Reuses upstream's cron parser and timezone handling so the expression means
// exactly what it would in a hermes job file.
import { Database } from "bun:sqlite";
import { CronParseError, matchesBetween, parseCron } from "/app/src/cron";
import { resolveTimezoneOffsetMinutes } from "/app/src/timezone";

const DB_PATH = process.env.HERMES_STATE_DB || "/root/.claude/hermes/state.db";
const TICK_MS = 30_000;

function log(msg: string): void {
  console.log(`[hermes] ${msg}`);
}

export function resetSessions(dbPath: string = DB_PATH): number {
  // readwrite without create: hermes owns the file and makes it on first start.
  const db = new Database(dbPath, { readwrite: true, create: false });
  try {
    db.exec("PRAGMA busy_timeout = 30000");
    return db
      .prepare(
        "UPDATE sessions SET claude_session_id = NULL, turn_count = 0, compact_warned = 0 " +
          "WHERE claude_session_id IS NOT NULL",
      )
      .run().changes;
  } finally {
    db.close();
  }
}

function runReset(): void {
  try {
    log(`session reset: ${resetSessions()} conversation(s) cleared`);
  } catch (err) {
    log(`session reset failed: ${err instanceof Error ? err.message : String(err)}`);
  }
}

function schedule(expr: string): void {
  const fields = parseCron(expr);
  log(`session reset scheduled (${expr}, ${process.env.TZ || "UTC"})`);
  let last = new Date();
  // Short ticks plus a catch-up window, so a clock change or a suspended host
  // can't skip a reset; several missed matches still mean one reset.
  setInterval(() => {
    const now = new Date();
    // Resolved every tick so a DST change moves the reset with local time.
    const offset = resolveTimezoneOffsetMinutes(undefined, process.env.TZ);
    if (matchesBetween(fields, last, now, offset).length > 0) runReset();
    last = now;
  }, TICK_MS);
}

if (import.meta.main) {
  if (process.argv[2] === "--now") {
    runReset();
    process.exit(0);
  }
  const expr = (process.env.SESSION_RESET_CRON || "").trim();
  if (!expr || expr === "off") process.exit(0);
  try {
    schedule(expr);
  } catch (err) {
    const detail = err instanceof CronParseError ? err.message : String(err);
    log(`SESSION_RESET_CRON: ${detail}; sessions won't be reset`);
    process.exit(1);
  }
}
