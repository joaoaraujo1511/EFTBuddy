// Pure helpers for the per-browser progress blob and the backup file.
//
// They live apart from app.js so they can be tested with Node's built-in runner
// (`node --test "assets/js/*.test.mjs"`): localStorage is the only durable copy of a
// visitor's progress, and these functions decide what ends up in it. Nothing in
// this file may touch `window`, `document` or storage. app.js does the I/O.

// Schema version for the progress blob / backup file. The localStorage KEY
// carries the same version (the on-disk contract); this integer is the logical
// version stamped into exports and checked on import.
//
//   v1 - flat: one set of progress shared by both game modes.
//   v2 - namespaced per game mode (`{modes: {pvp: {...}, pve: {...}}}`), because
//        PVP and PVE are separate progressions in-game.
export const PROGRESS_VERSION = 2

// The game modes a blob carries a slice for. Mirrors EftBuddy.Progress.modes/0
// and EftBuddy.Operator.game_modes/0.
export const GAME_MODES = ["pvp", "pve"]

// The only operator-pref keys we recognise, split the same way the server splits
// them (EftBuddy.Operator): the mode selector and the rail state are global, and
// everything describing the character is per mode. On import we keep ONLY these
// (see `sanitizePrefs`) so a shared or hand-edited backup can't stuff arbitrary
// or oversized junk into the `eft_prefs` cookie - which is sent on every request
// and is size-capped server-side. Values themselves are re-validated and clamped
// by `Operator` on the server, so we only need to gate the keys.
export const GLOBAL_PREF_KEYS = ["mode", "rail_collapsed"]
export const MODE_PREF_KEYS = ["pmc_level", "scav_karma", "faction"]

// A plain (non-array) object, or `{}` for anything else. Used to defend every
// read/merge against a corrupt or hand-edited blob so a single bad value can
// never throw or wipe good state.
export function asObject(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {}
}

// A payload is a valid backup when it's our tagged object carrying a progress
// object. `prefs` is optional (older/partial files). The `app` tag stops an
// unrelated JSON file from being mistaken for a backup.
export function isValidBackup(payload) {
  return !!payload && typeof payload === "object" &&
    payload.app === "eft-buddy" &&
    !!payload.progress && typeof payload.progress === "object" && !Array.isArray(payload.progress)
}

// Keep only the operator-pref keys we know about, in the nested per-mode shape,
// dropping everything else so an imported backup can't inject
// arbitrary/oversized entries into the prefs cookie. Value validation is the
// server's job (Operator parses + clamps every one of them).
export function sanitizePrefs(prefs) {
  const src = asObject(prefs)
  const out = {}
  for (const key of GLOBAL_PREF_KEYS) if (key in src) out[key] = src[key]

  const slices = asObject(src.modes)
  out.modes = {}
  for (const mode of GAME_MODES) {
    const slice = asObject(slices[mode])
    const kept = {}
    for (const key of MODE_PREF_KEYS) if (key in slice) kept[key] = slice[key]
    out.modes[mode] = kept
  }
  return out
}

// Coerce a progress blob into the canonical per-mode shape, dropping anything
// unrecognised - including keys outside the allow-list, which mirrors
// EftBuddy.Progress' `@slice_keys`. The server drops them too, but doing it here
// as well means we never WRITE a malformed blob to localStorage in the first
// place. That matters more since `eft:store` began merging: without the
// allow-list, junk from a hand-edited or imported blob would live in localStorage
// forever, be handed back up on every restore, and be silently discarded
// server-side each time. Keep this list in step with `EftBuddy.Progress`.
export const PROGRESS_SLICE_KEYS = [
  "completed_tasks",
  "tasks_watchlist",
  "items_watchlist",
  "events_watchlist",
  "hideout_checks",
  "hideout",
  "flea_favorites",
]

export function sanitizeProgress(progress) {
  const src = asObject(progress)
  const slices = asObject(src.modes)
  const out = { modes: {} }
  for (const mode of GAME_MODES) {
    const slice = asObject(slices[mode])
    const kept = {}
    for (const key of PROGRESS_SLICE_KEYS) if (key in slice) kept[key] = slice[key]
    out.modes[mode] = kept
  }
  return out
}

// Fold a server blob into the local one, per mode: the incoming value wins for
// every key it CARRIES, and keys it omits are kept.
//
// The distinction is the whole point. The server is authoritative about what it
// says; it is not authoritative about silence, because its copy lives in an
// `EftBuddy.OperatorSession` process that can die (4h idle, a crash, a deploy)
// and come back empty while localStorage - the ONLY durable copy - still holds
// the real history. Replacing meant a single write from a resurrected session
// erased everything the operator had tracked.
//
// Per MODE, not per blob, because a shallow `{...local, ...incoming}` on a
// nested `modes` payload would drop the sibling mode's slice wholesale. Per KEY
// within a mode is safe: a slice's values are whole lists that the server
// replaces deliberately (unwatchlisting sends the shorter list, it does not
// remove the key), so only absence is ever ignored.
//
// This browser is the only party that can see both copies, which is why the
// merge has to live here rather than server-side. Shrinking is therefore never
// implicit: only this browser's own Reset and Import rewrite storage wholesale.
export function mergeProgress(local, incoming) {
  const base = sanitizeProgress(local)
  const patch = sanitizeProgress(incoming)
  const out = { modes: {} }
  for (const mode of GAME_MODES) {
    out.modes[mode] = { ...base.modes[mode], ...patch.modes[mode] }
  }
  return out
}

// Normalize an imported payload to the current schema: sanitize the progress
// blob and prefs, and surface the file's version.
//
// There is no v1 -> v2 migration. v1 backups hold a single shared progress set
// with no way to say which mode it belongs to, and quietly filing someone's
// whole history under PVP would be a guess dressed up as a migration. `import`
// rejects them with an explanation instead. A future v2 -> v3 change should
// step-migrate here (`while (version < PROGRESS_VERSION) { ...; version++ }`).
export function migrateBackup(payload) {
  return {
    version: Number(payload.version) || 1,
    progress: sanitizeProgress(payload.progress),
    prefs: sanitizePrefs(payload.prefs),
  }
}

// Which schema a valid backup file is in, relative to this build: "ok" for the
// current version, "newer" for a file from a later build (refused, since we
// cannot know its shape), "older" for a v1 file (refused, because v1 has no way
// to say which mode its progress belongs to - see `migrateBackup`).
export function backupVersion(payload) {
  const version = Number(payload && payload.version) || 1
  if (version > PROGRESS_VERSION) return "newer"
  if (version < PROGRESS_VERSION) return "older"
  return "ok"
}
