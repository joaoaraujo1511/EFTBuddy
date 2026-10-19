// Tests for the browser-side progress helpers: `node --test "assets/js/*.test.mjs"`.
//
// localStorage is the only durable copy of a visitor's progress, and these
// functions decide what is written to it on every server push and every backup
// import. Nothing on the server can observe what the browser keeps, so this is
// the only place their behaviour is pinned.
import { test } from "node:test"
import assert from "node:assert/strict"

import {
  PROGRESS_VERSION,
  backupVersion,
  isValidBackup,
  mergeProgress,
  migrateBackup,
  sanitizePrefs,
  sanitizeProgress,
} from "./progress.js"

const blob = (pvp = {}, pve = {}) => ({ modes: { pvp, pve } })

test("sanitizeProgress always returns both mode slices", () => {
  for (const junk of [null, undefined, 7, "x", [], { modes: [] }, { modes: { pvp: [] } }]) {
    assert.deepEqual(sanitizeProgress(junk), blob())
  }
})

test("sanitizeProgress keeps only allow-listed keys", () => {
  const out = sanitizeProgress(blob({ completed_tasks: ["a"], bogus: 1 }, { hideout: { workbench: 2 } }))
  assert.deepEqual(out, blob({ completed_tasks: ["a"] }, { hideout: { workbench: 2 } }))
})

test("mergeProgress: a key the server omits is kept", () => {
  // A resurrected, empty session must never be able to erase what this browser
  // holds just by not mentioning it.
  const local = blob({ completed_tasks: ["a", "b"], items_watchlist: ["x"] })
  const out = mergeProgress(local, blob({ items_watchlist: ["x", "y"] }))
  assert.deepEqual(out.modes.pvp.completed_tasks, ["a", "b"])
  assert.deepEqual(out.modes.pvp.items_watchlist, ["x", "y"])
})

test("mergeProgress: a key the server sends replaces the local one", () => {
  // Unwatchlisting sends the shorter list; that has to take effect.
  const out = mergeProgress(blob({ items_watchlist: ["x", "y"] }), blob({ items_watchlist: ["x"] }))
  assert.deepEqual(out.modes.pvp.items_watchlist, ["x"])
})

test("mergeProgress: a write to one mode never touches the other", () => {
  // A shallow `{...local, ...incoming}` on the nested shape would drop the
  // sibling mode wholesale.
  const local = blob({ completed_tasks: ["pvp-quest"] }, { completed_tasks: ["pve-quest"] })
  const out = mergeProgress(local, { modes: { pvp: { completed_tasks: ["pvp-quest", "new"] } } })
  assert.deepEqual(out.modes.pve.completed_tasks, ["pve-quest"])
  assert.deepEqual(out.modes.pvp.completed_tasks, ["pvp-quest", "new"])
})

test("mergeProgress survives corrupt input on either side", () => {
  const local = blob({ completed_tasks: ["a"] })
  assert.deepEqual(mergeProgress(local, "garbage"), local)
  assert.deepEqual(mergeProgress(null, blob({ completed_tasks: ["a"] })), local)
})

test("sanitizePrefs keeps only known keys, per mode", () => {
  const out = sanitizePrefs({
    mode: "pve",
    rail_collapsed: true,
    evil: "x".repeat(10_000),
    modes: { pvp: { pmc_level: 40, scav_karma: 1e308, junk: 1 }, pve: { faction: "bear" }, other: {} },
  })
  assert.deepEqual(out, {
    mode: "pve",
    rail_collapsed: true,
    modes: { pvp: { pmc_level: 40, scav_karma: 1e308 }, pve: { faction: "bear" } },
  })
})

test("isValidBackup requires our tag and a progress object", () => {
  assert.equal(isValidBackup({ app: "eft-buddy", progress: {} }), true)
  assert.equal(isValidBackup({ app: "other", progress: {} }), false)
  assert.equal(isValidBackup({ app: "eft-buddy", progress: [] }), false)
  assert.equal(isValidBackup({ app: "eft-buddy" }), false)
  assert.equal(isValidBackup(null), false)
})

test("backupVersion refuses v1 and future files", () => {
  // v1 has one shared progress set with no way to tell which mode it was;
  // quietly filing it under PVP would be a guess.
  assert.equal(backupVersion({ version: PROGRESS_VERSION }), "ok")
  assert.equal(backupVersion({ version: 1 }), "older")
  assert.equal(backupVersion({}), "older")
  assert.equal(backupVersion({ version: PROGRESS_VERSION + 1 }), "newer")
})

test("migrateBackup sanitizes both halves of the file", () => {
  const out = migrateBackup({
    version: 2,
    progress: blob({ completed_tasks: ["a"], bogus: 1 }),
    prefs: { mode: "pvp", evil: 1 },
  })
  assert.equal(out.version, 2)
  assert.deepEqual(out.progress, blob({ completed_tasks: ["a"] }))
  assert.deepEqual(out.prefs, { mode: "pvp", modes: { pvp: {}, pve: {} } })
})
