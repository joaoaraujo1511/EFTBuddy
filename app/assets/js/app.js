// =============================================================================
// EFT-Buddy - client runtime
// -----------------------------------------------------------------------------
// Brand-new hook set for the OPERATOR HUD frontend:
//   * Hud     - per-browser persistence bridge (cookie prefs + localStorage
//               progress) so the no-account tracker survives reloads.
//   * TacMap  - dependency-free pan/zoom/marker viewer for the map
//               base art (vendored SVGs, tarkov.dev tile pyramids, or
//               flat 2D/3D renders), styled to the HUD palette.
//   * imgFallback - CSP-safe <img> error handler (reveals an inline glyph).
//
// The LiveView <-> client event names (eft:restore / eft:cookie / eft:store /
// eft:clear) are the server contract consumed by the OperatorState on_mount
// and the Tasks/Hideout LiveViews; the implementations below are all new.
// =============================================================================

import "phoenix_html"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import { hooks as colocatedHooks } from "phoenix-colocated/eft_buddy"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// ── HUD palette (mirrors app.css @theme tokens; used by JS-painted controls) ─
// Keep these hex values in sync with the --color-* tokens in app.css.
const HUD = {
  ink950: "#121212",
  ink900: "#181818",
  ink850: "#1e1e1e",
  ink700: "#333333",
  line: "#2c2c2c",
  lineStrong: "#3b3b3b",
  fog: "#bcb9a6",
  fogDim: "#82806d",
  amber: "#9a8866",
  olive: "#7c854f",
}
// Translucent panel fill derived from ink-950 (#121212 -> rgb 18,18,18), used
// for the map's floating control/menu surfaces.
const HUD_PANEL_BG = "rgba(18,18,18,0.82)"
const HUD_MENU_BG = "rgba(18,18,18,0.96)"

// =============================================================================
// Persistence bridge
// =============================================================================
const PREFS_COOKIE = "eft_prefs"               // small sidebar/HUD prefs
const PROGRESS_KEY = "eft_buddy_state_v2"       // large per-page progress
// Storage keys from earlier schemas. Only used to clean them up on a reset: a
// bumped key means an old blob is simply never read, which is how the flat
// (pre-per-mode) layout was retired without a migration.
const LEGACY_PROGRESS_KEYS = ["eft_buddy_state_v1"]
const COOKIE_MAX_AGE = 60 * 60 * 24 * 365       // ~1 year

// Schema version for the progress blob / backup file. The localStorage KEY
// carries the same version (the on-disk contract); this integer is the logical
// version stamped into exports and checked on import.
//
//   v1 - flat: one set of progress shared by both game modes.
//   v2 - namespaced per game mode (`{modes: {pvp: {...}, pve: {...}}}`), because
//        PVP and PVE are separate progressions in-game.
const PROGRESS_VERSION = 2

// The game modes a blob carries a slice for. Mirrors EftBuddy.Progress.modes/0
// and EftBuddy.Operator.game_modes/0.
const GAME_MODES = ["pvp", "pve"]

// The only operator-pref keys we recognise, split the same way the server splits
// them (EftBuddy.Operator): the mode selector and the rail state are global, and
// everything describing the character is per mode. On import we keep ONLY these
// (see `sanitizePrefs`) so a shared or hand-edited backup can't stuff arbitrary
// or oversized junk into the `eft_prefs` cookie - which is sent on every request
// and is size-capped server-side. Values themselves are re-validated and clamped
// by `Operator` on the server, so we only need to gate the keys.
const GLOBAL_PREF_KEYS = ["mode", "rail_collapsed"]
const MODE_PREF_KEYS = ["pmc_level", "scav_karma", "faction"]

// Upper bound on an imported backup file. Real progress is a few KB; this is a
// generous ceiling that still rejects a file crafted to blow past the
// localStorage quota or bloat the connect-time socket payload.
const MAX_BACKUP_BYTES = 1024 * 1024 // 1 MB

// A plain (non-array) object, or `{}` for anything else. Used to defend every
// read/merge against a corrupt or hand-edited blob so a single bad value can
// never throw or wipe good state.
function asObject(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {}
}

// Always hands back the canonical per-mode shape, so a corrupt or hand-edited
// blob can't be handed up to the server or written into an export as-is.
function readProgress() {
  try {
    const raw = window.localStorage.getItem(PROGRESS_KEY)
    if (!raw) return sanitizeProgress({})
    return sanitizeProgress(JSON.parse(raw))
  } catch (_e) { return sanitizeProgress({}) }
}

// Returns true on success, false if the write failed (e.g. localStorage quota
// exceeded). Callers that must not lose the prior state on a failed write
// (import) check the result instead of silently continuing.
function writeProgress(state) {
  try {
    window.localStorage.setItem(PROGRESS_KEY, JSON.stringify(asObject(state)))
    return true
  } catch (_e) {
    return false
  }
}

// Wipe all per-browser state: the localStorage progress blob and the prefs
// cookie. Shared by the server-driven `eft:clear` event and the operator's
// own "Reset progress" backup action.
function clearAll() {
  try {
    window.localStorage.removeItem(PROGRESS_KEY)
    // Sweep up blobs from retired schema versions too, so a reset genuinely
    // empties this browser instead of leaving dead keys behind forever.
    for (const key of LEGACY_PROGRESS_KEYS) window.localStorage.removeItem(key)
  } catch (_e) {}
  document.cookie = `${PREFS_COOKIE}=; ${cookieFlags()}; max-age=0`
}

// =============================================================================
// Progress backup - export / import / reset of the per-browser state. Since
// the tracker has no account, this is the user's only backup + cross-device
// path: a single JSON file carrying both the localStorage progress blob and
// the cookie-backed operator prefs, wrapped with a version so imports from an
// older schema can be migrated forward rather than rejected.
// =============================================================================
function buildBackup() {
  return {
    app: "eft-buddy",
    kind: "progress-backup",
    version: PROGRESS_VERSION,
    exportedAt: new Date().toISOString(),
    progress: readProgress(),
    prefs: readPrefs(),
  }
}

function backupFilename() {
  return `eft-buddy-backup-${new Date().toISOString().slice(0, 10)}.json`
}

function downloadBackup() {
  let url
  try {
    const blob = new Blob([JSON.stringify(buildBackup(), null, 2)], { type: "application/json" })
    url = URL.createObjectURL(blob)
    const a = document.createElement("a")
    a.href = url
    a.download = backupFilename()
    document.body.appendChild(a)
    a.click()
    a.remove()
  } catch (_e) {
    window.alert("Sorry - the backup file couldn't be created.")
  } finally {
    if (url) setTimeout(() => URL.revokeObjectURL(url), 0)
  }
}

// A payload is a valid backup when it's our tagged object carrying a progress
// object. `prefs` is optional (older/partial files). The `app` tag stops an
// unrelated JSON file from being mistaken for a backup.
function isValidBackup(payload) {
  return !!payload && typeof payload === "object" &&
    payload.app === "eft-buddy" &&
    !!payload.progress && typeof payload.progress === "object" && !Array.isArray(payload.progress)
}

// Keep only the operator-pref keys we know about, in the nested per-mode shape,
// dropping everything else so an imported backup can't inject
// arbitrary/oversized entries into the prefs cookie. Value validation is the
// server's job (Operator parses + clamps every one of them).
function sanitizePrefs(prefs) {
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
const PROGRESS_SLICE_KEYS = [
  "completed_tasks",
  "tasks_watchlist",
  "items_watchlist",
  "events_watchlist",
  "hideout_checks",
  "hideout",
  "flea_favorites",
]

function sanitizeProgress(progress) {
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
// implicit: `eft:clear` is the one channel allowed to remove keys.
function mergeProgress(local, incoming) {
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
function migrateBackup(payload) {
  return {
    version: Number(payload.version) || 1,
    progress: sanitizeProgress(payload.progress),
    prefs: sanitizePrefs(payload.prefs),
  }
}

// Replace (not merge) the local state with an imported backup. Restore
// semantics are "make this device look like the backup", so a stale key in
// the current blob shouldn't survive the import. Writes progress FIRST and
// bails if that fails (quota) so we never end up with imported prefs applied
// on top of the old, unchanged progress. Returns true only on a full write.
function applyBackup(payload) {
  const { progress, prefs } = migrateBackup(payload)
  if (!writeProgress(progress)) return false
  writePrefs(prefs)
  return true
}

function readPrefs() {
  const m = document.cookie.match(/(?:^|;\s*)eft_prefs=([^;]*)/)
  if (!m) return {}
  try {
    const parsed = JSON.parse(decodeURIComponent(m[1]))
    return parsed && typeof parsed === "object" ? parsed : {}
  } catch (_e) { return {} }
}

function cookieFlags() {
  const secure = window.location.protocol === "https:" ? "; secure" : ""
  return `path=/; samesite=lax${secure}`
}

function writePrefs(prefs) {
  const value = encodeURIComponent(JSON.stringify(prefs))
  document.cookie = `${PREFS_COOKIE}=${value}; ${cookieFlags()}; max-age=${COOKIE_MAX_AGE}`
}

const Hud = {
  mounted() {
    // Hand the local progress slice (localStorage) up to the server. The
    // server can never read localStorage itself, so this is how progress
    // enters a fresh operator session.
    //
    // This hook lives in the per-LiveView app layout, so it re-mounts on every
    // live navigation and this push repeats - but seeding is once-only
    // server-side (see EftBuddy.OperatorSession), so only the FIRST push of a
    // session does anything. That matters: the server is authoritative once
    // seeded, and a re-push must never resurrect stale localStorage over newer
    // in-session work.
    //
    // NOTE: there is deliberately no `eft:prefs` push here any more. Operator
    // prefs used to be re-pushed on every navigation to repair the stale
    // connect-time session, which is exactly what made the HUD flash: the page
    // rendered defaults first and snapped to the real values when this reply
    // landed. Prefs are now resolved server-side before the first render.
    this.pushEvent("eft:restore", readProgress())

    // `eft:cookie` REPLACES. The server holds the complete, canonical pref set
    // and re-derives it from scratch on every write, and prefs are cheap to
    // re-enter, so there is nothing to protect against absence here.
    this.handleEvent("eft:cookie", (prefs) => {
      if (!prefs || typeof prefs !== "object") return
      writePrefs(sanitizePrefs(prefs))
    })

    // `eft:store` MERGES per mode - see `mergeProgress`. Progress is the one
    // piece of state whose only durable copy is this localStorage blob, so a
    // server answer may add to it and correct it but must never be able to
    // silently shrink it. `eft:clear` is the explicit channel for that.
    this.handleEvent("eft:store", (progress) => {
      if (!progress || typeof progress !== "object") return
      writeProgress(mergeProgress(readProgress(), progress))
    })

    this.handleEvent("eft:clear", () => clearAll())
  },

  // A socket REJOIN does not re-run `mounted()`: LiveView patches the existing
  // DOM in place and only calls `mounted()` for nodes the join patch reports as
  // newly added, so the `eft:restore` push above would never repeat. That is the
  // worst possible moment to stay silent, because a rejoin is exactly when the
  // session is most likely to be gone - a >4h-idle tab, a crash, or a deploy,
  // which kills every session at once while every open tab quietly rejoins.
  // Without this the server would serve those tabs from an empty session and
  // have no way of learning otherwise.
  //
  // Re-pushing is cheap and safe: seeding is once-only server-side, so a push
  // against a session that IS still seeded is answered `:unchanged`.
  reconnected() {
    this.pushEvent("eft:restore", readProgress())
  },
}

// =============================================================================
// BACKUP - the top-bar "Backup" menu (export / import / reset). All three
// actions are pure client operations on localStorage + the prefs cookie, so
// they work regardless of socket state and never round-trip. The hook wires
// the menu's buttons (delegated, so they survive LiveView patches) and the
// hidden file input; import and reset do a full page reload afterwards so the
// server re-hydrates the operator prefs from the (now rewritten) cookie and
// every LiveView re-reads the restored progress blob on reconnect.
// =============================================================================
const Backup = {
  mounted() {
    this.details = this.el.querySelector("[data-backup-root]")
    this.fileInput = this.el.querySelector("[data-backup-file]")

    this.close = () => { if (this.details) this.details.open = false }

    this.onClick = (e) => {
      const btn = e.target.closest && e.target.closest("[data-backup-action]")
      if (!btn || !this.el.contains(btn)) return
      e.preventDefault()
      this.close()
      switch (btn.dataset.backupAction) {
        case "export": downloadBackup(); break
        case "import": if (this.fileInput) this.fileInput.click(); break
        case "reset": this.reset(); break
      }
    }
    this.el.addEventListener("click", this.onClick)

    this.onFile = (e) => {
      const file = e.target.files && e.target.files[0]
      e.target.value = "" // let the same file be re-picked later
      if (file) this.import(file)
    }
    if (this.fileInput) this.fileInput.addEventListener("change", this.onFile)

    // Dismiss the open menu on an outside click or Escape.
    this.onDocClick = (e) => {
      if (this.details && this.details.open && !this.el.contains(e.target)) this.close()
    }
    this.onKey = (e) => { if (e.key === "Escape") this.close() }
    document.addEventListener("click", this.onDocClick)
    document.addEventListener("keydown", this.onKey)
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    if (this.fileInput) this.fileInput.removeEventListener("change", this.onFile)
    document.removeEventListener("click", this.onDocClick)
    document.removeEventListener("keydown", this.onKey)
  },
  import(file) {
    if (file.size > MAX_BACKUP_BYTES) {
      window.alert("That file is too large to be an EFT-Buddy backup.")
      return
    }
    const reader = new FileReader()
    reader.onload = () => {
      let payload
      try { payload = JSON.parse(reader.result) } catch (_e) { payload = null }
      if (!isValidBackup(payload)) {
        window.alert("That doesn't look like an EFT-Buddy backup file.")
        return
      }
      const version = Number(payload.version) || 1
      if (version > PROGRESS_VERSION) {
        window.alert("This backup was made by a newer version of EFT-Buddy and can't be imported here.")
        return
      }
      if (version < PROGRESS_VERSION) {
        window.alert("This backup predates separate PVP and PVE profiles, so there's no way to tell which mode its progress belongs to. It can't be imported.")
        return
      }
      if (!window.confirm("Import this backup? It replaces all progress and settings on this device.")) return
      if (!applyBackup(payload)) {
        window.alert("Import failed - your browser's storage may be full. Your current progress was left unchanged.")
        return
      }
      reloadViaServerReset()
    }
    reader.onerror = () => window.alert("Sorry - that file couldn't be read.")
    reader.readAsText(file)
  },
  reset() {
    if (!window.confirm("Reset all progress and settings on this device? This can't be undone unless you've exported a backup.")) return
    clearAll()
    reloadViaServerReset()
  },
}

// Both "reset" and "import" rewrite this browser's durable storage and then
// reload so the app re-hydrates from it. Because the server is authoritative for
// live operator state (see EftBuddy.OperatorSession), it must also stop serving
// what it currently holds - otherwise the reload is handed the pre-reset values
// and the action looks like it did nothing.
//
// We do that with a plain NAVIGATION rather than a socket push. The backup
// actions must work while the socket is down (that's why they're pure client
// operations), and a push issued immediately before a reload can be lost with
// the dying LiveView. `/session/reset` resets the current session, rotates the
// operator token so this tab gets a clean session seeded from the storage we
// just wrote, and redirects back into the app.
//
// It is a form POST, not a link. The route discards progress and rotates the
// token, so as a GET it was triggerable by a cross-site top-level navigation
// (`same_site: "Lax"` still sends the session cookie on those) - one posted link
// was enough to wipe a visitor's tracker. POSTing with the CSRF token brings it
// under `:protect_from_forgery`. Building and submitting a real form (rather
// than fetch()) keeps the behaviour a genuine navigation, which is the whole
// reason this path exists: the redirect that follows is what reloads the page.
function reloadViaServerReset() {
  const returnTo = window.location.pathname + window.location.search

  const form = document.createElement("form")
  form.method = "post"
  form.action = "/session/reset"
  form.style.display = "none"

  for (const [name, value] of [["_csrf_token", csrfToken], ["return_to", returnTo]]) {
    const input = document.createElement("input")
    input.type = "hidden"
    input.name = name
    input.value = value
    form.appendChild(input)
  }

  document.body.appendChild(form)
  form.submit()
}

// =============================================================================
// SHELL - the three-column console chrome (left nav rail + right operator
// drawer). The DESKTOP collapse states (rail width / drawer open) are owned by
// the server and persisted through the cookie bridge, so all this hook manages
// is the MOBILE, off-canvas rail: an ephemeral, client-only overlay that never
// round-trips. The rail's mobile transform is re-applied on every LiveView
// patch (via `updated()`) because morphdom would otherwise clobber the inline
// style; on desktop the rail is pinned open by the `lg:translate-x-0` class so
// this hook is effectively a no-op there.
// =============================================================================
const Shell = {
  mounted() {
    this.rail = this.el.querySelector("[data-shell-rail]")
    this.backdrop = this.el.querySelector("[data-shell-backdrop]")
    this.railOpen = false

    this.apply = () => {
      if (this.rail) this.rail.style.transform = this.railOpen ? "translateX(0)" : ""
      if (this.backdrop) this.backdrop.style.display = this.railOpen ? "block" : "none"
      // Lock body scroll only while the mobile overlay is up.
      document.body.style.overflow = this.railOpen ? "hidden" : ""
    }
    this.setRail = (v) => { this.railOpen = v; this.apply() }

    this.onClick = (e) => {
      const t = e.target
      if (t.closest("[data-shell-rail-open]")) { e.preventDefault(); this.setRail(true); return }
      if (t.closest("[data-shell-rail-close]")) { e.preventDefault(); this.setRail(false); return }
      if (t.closest("[data-shell-backdrop]")) { this.setRail(false); return }
      // Any nav link tap inside the rail dismisses the overlay so the
      // destination page isn't left hidden behind it.
      if (this.rail && this.rail.contains(t) && t.closest("a[href]")) this.setRail(false)
    }
    this.onKey = (e) => { if (e.key === "Escape" && this.railOpen) this.setRail(false) }

    document.addEventListener("click", this.onClick)
    document.addEventListener("keydown", this.onKey)
    this.apply()
  },
  updated() { if (this.apply) this.apply() },
  destroyed() {
    document.removeEventListener("click", this.onClick)
    document.removeEventListener("keydown", this.onKey)
    document.body.style.overflow = ""
  },
}

// =============================================================================
// TacMap - interactive map viewer (pan / zoom / floors / markers / popups).
// Fully self-contained, no map library. Reads its config from `data-tac` JSON
// on the host element; owns all DOM inside it (host has phx-update="ignore").
// =============================================================================
// Marker types are declared once, on the server
// (EftBuddyWeb.MapsLive.Markers), and arrive as `markerTypes` in the viewer
// payload: `{ type, label, icon, hidden }` in panel order, listing only the
// layers this map actually has. All that is left here is the last-ditch icon
// for a type the server didn't describe.
const MARKER_BASE = "/images/maps/markers"
const MARKER_FALLBACK_ICON = `${MARKER_BASE}/extract_shared.webp`

function hudButton(label, title) {
  const b = document.createElement("button")
  b.type = "button"
  b.textContent = label
  if (title) { b.title = title; b.setAttribute("aria-label", title) }
  // Reuses the HUD focus ring already defined in app.css, so keyboard users
  // can see where they are without any new CSS.
  b.classList.add("hud-focus")
  Object.assign(b.style, {
    minWidth: "34px", height: "34px", padding: "0 9px",
    fontSize: "16px", lineHeight: "1", color: HUD.fog,
    background: HUD.ink850, border: `1px solid ${HUD.line}`,
    borderRadius: "2px", cursor: "pointer", userSelect: "none",
    display: "inline-flex", alignItems: "center", justifyContent: "center",
    fontFamily: "Oswald, sans-serif",
  })
  return b
}

// Inline heroicon (outline/24) path data, embedded so the JS-painted map
// controls don't depend on Tailwind emitting `hero-*` mask classes for
// names that only appear in this file.
const HUD_ICON_PATHS = {
  "zoom-in": "m21 21-5.197-5.197m0 0A7.5 7.5 0 1 0 5.196 5.196a7.5 7.5 0 0 0 10.607 10.607ZM10.5 7.5v6m3-3h-6",
  "zoom-out": "m21 21-5.197-5.197m0 0A7.5 7.5 0 1 0 5.196 5.196a7.5 7.5 0 0 0 10.607 10.607ZM13.5 10.5h-6",
  "reset": "M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0 3.181 3.183a8.25 8.25 0 0 0 13.803-3.7M4.031 9.865a8.25 8.25 0 0 1 13.803-3.7l3.181 3.182m0-4.991v4.99",
}
function hudIcon(name) {
  const ns = "http://www.w3.org/2000/svg"
  const svg = document.createElementNS(ns, "svg")
  svg.setAttribute("viewBox", "0 0 24 24")
  svg.setAttribute("fill", "none")
  svg.setAttribute("stroke", "currentColor")
  svg.setAttribute("stroke-width", "1.7")
  Object.assign(svg.style, { width: "18px", height: "18px", pointerEvents: "none" })
  const path = document.createElementNS(ns, "path")
  path.setAttribute("stroke-linecap", "round")
  path.setAttribute("stroke-linejoin", "round")
  path.setAttribute("d", HUD_ICON_PATHS[name] || "")
  svg.appendChild(path)
  return svg
}
function hudIconButton(name, title) {
  const b = hudButton("", title)
  b.appendChild(hudIcon(name))
  return b
}

const TacMap = {
  mounted() {
    let cfg
    try { cfg = JSON.parse(this.el.dataset.tac || "{}") } catch (_e) { cfg = {} }
    this.cfg = cfg
    this.abort = new AbortController()
    this.cam = { scale: 1, tx: 0, ty: 0, fit: 1 }
    this.pointers = new Map()
    this.pinch = 0
    this.hidden = new Set()
    this.floor = null
    // The base art (SVG fetch or tile mosaic) is what establishes the viewBox
    // and scene size, so floor selection and marker rendering both wait on it.
    this.baseReady = false
    // Markers / labels / marker descriptors arrive over the socket, not in
    // data-tac (see EftBuddyWeb.MapsLive.Show), so rendering waits on them too.
    this.dataReady = false
    // Available viewer modes, in display order: the interactive base
    // (SVG or tile pyramid) when this map has projection config, then
    // the flat 2D / 3D static renders (each possibly multi-variant).
    this.variants = this.cfg.imageVariants || {}
    this.credit = null
    this.modes = this.computeModes()
    this.mode = this.modes[0] || "interactive"
    this.variantIndex = { "2d": 0, "3d": 0 }
    this.build()
    this.setupProjection()
    this.handleEvent("tac:data", (d) => this.onData(d))
    this.loadBase()
  },
  destroyed() { if (this.abort) this.abort.abort() },

  computeModes() {
    const modes = []
    if (this.cfg.projection === "svg" || this.cfg.projection === "tile") modes.push("interactive")
    if (Array.isArray(this.variants["2d"]) && this.variants["2d"].length) modes.push("2d")
    if (Array.isArray(this.variants["3d"]) && this.variants["3d"].length) modes.push("3d")
    return modes
  },
  isInteractive() { return this.mode === "interactive" },
  hasInteractive() { return this.modes.includes("interactive") },

  // Load whatever the initial mode needs. The interactive base (if any)
  // is always built up front so switching back to it is instant; static
  // images load lazily on first switch.
  loadBase() {
    if (this.cfg.projection === "svg") this.loadSvg()
    else if (this.cfg.projection === "tile") this.renderTiles()
    if (!this.isInteractive()) this.showImage(this.mode)
  },
  // Switching back to the interactive base drops the per-render credit; the
  // panel header credits that base already.
  clearCredit() { if (this.credit) this.credit.style.display = "none" },

  // Single entry point for the centred status text, so every message also
  // reaches the live region. Passing `null` keeps the last text (nothing to
  // re-announce) and just hides the overlay.
  setStatus(text, show) {
    if (!this.status) return
    if (text != null) this.status.textContent = text
    this.status.style.display = show ? "flex" : "none"
    if (this.live && text != null && this.live.textContent !== text) this.live.textContent = text
  },

  // Marker payload from the server. Merged into cfg so every consumer keeps
  // reading one object. Re-sent on every LiveView reconnect (mount/3 re-runs
  // while this hook stays alive), so it has to be idempotent: clearData()
  // removes the previous render and `_defaulted` keeps the user's toggles.
  onData(d) {
    if (!d) return
    this.cfg.markers = d.markers || []
    this.cfg.labels = d.labels || []
    this.cfg.markerTypes = d.markerTypes || []
    this._typeIndex = null
    this.dataReady = true
    this.renderData()
  },
  renderData() {
    if (!this.dataReady || !this.baseReady) return
    this.clearData()
    this.renderMarkers()
    this.renderLabels()
  },
  clearData() {
    this.closePopup()
    ;(this.pins || []).forEach((p) => p.remove())
    ;(this.labelEls || []).forEach((r) => r.el && r.el.remove())
    this.pins = []
    this.labelEls = []
    this.activePin = null
    if (this._markerPanel) { this._markerPanel.remove(); this._markerPanel = null }
  },

  // Two children: the options column and the map viewport, laid out as a flex
  // row. Everything that draws or receives pointer input lives inside the
  // viewport, so the column can dock beside the map (shrinking it) rather than
  // floating over it — which is what made it fight the map for wheel events
  // and hide the art underneath.
  build() {
    this.el.innerHTML = ""
    this.el.style.position = "relative"
    this.el.style.display = "flex"
    this.el.style.background = HUD.ink950

    // Created first so flex-row puts it on the left without needing `order`.
    // It stays in this position in the DOM in both docked and overlay modes;
    // only its styles change (see layout()).
    this.leftStack = document.createElement("div")
    Object.assign(this.leftStack.style, {
      display: "flex", flexDirection: "column", gap: "8px",
      zIndex: "5", overflowY: "auto",
    })
    this.el.appendChild(this.leftStack)
    this.hudPanels = []

    this.viewport = document.createElement("div")
    Object.assign(this.viewport.style, {
      position: "relative", flex: "1 1 auto", minWidth: "0",
      overflow: "hidden", cursor: "grab", touchAction: "none",
      background: HUD.ink950,
    })
    this.viewport.className = "tac-viewport"
    this.viewport.tabIndex = 0
    // `application` rather than `img`: the pins inside are genuinely
    // interactive (an `img` role would erase them from the a11y tree), and it
    // is what stops browse mode from eating the arrow keys we pan with.
    this.viewport.setAttribute("role", "application")
    const mapName = this.el.dataset.mapName || "Interactive"
    this.viewport.setAttribute(
      "aria-label",
      `${mapName} map. Arrow keys pan, plus and minus zoom, 0 resets the view, Escape closes a marker.`,
    )
    this.el.appendChild(this.viewport)

    // A permanently-present announcer. `this.status` is toggled with
    // `display: none`, which removes it from the accessibility tree — so it
    // can't double as a live region.
    this.live = document.createElement("span")
    this.live.className = "sr-only"
    this.live.setAttribute("role", "status")
    this.live.setAttribute("aria-live", "polite")
    this.viewport.appendChild(this.live)

    this.content = document.createElement("div")
    Object.assign(this.content.style, {
      position: "absolute", top: "0", left: "0",
      transformOrigin: "0 0", willChange: "transform",
    })
    this.viewport.appendChild(this.content)

    this.layer = document.createElement("div")
    Object.assign(this.layer.style, {
      position: "absolute", inset: "0", pointerEvents: "none",
      zIndex: "4", overflow: "hidden",
    })
    // Grouped so a screen-reader user can step over the whole pin run at once
    // rather than tabbing through every marker on the map.
    this.layer.setAttribute("role", "group")
    this.layer.setAttribute("aria-label", "Map markers")
    this.viewport.appendChild(this.layer)
    this.pins = []
    this.activePin = null

    this.popup = this.makePopup()
    this.viewport.appendChild(this.popup)

    this.status = document.createElement("div")
    Object.assign(this.status.style, {
      position: "absolute", inset: "0", display: "flex",
      alignItems: "center", justifyContent: "center",
      color: HUD.fogDim, fontSize: "13px", letterSpacing: "0.12em",
      textTransform: "uppercase", fontFamily: "Oswald, sans-serif",
      pointerEvents: "none",
    })
    this.setStatus("Loading map...", true)
    this.viewport.appendChild(this.status)

    this.toolbar()
    this.layout()
    this.bindInput()
  },

  panel(heading) {
    const p = document.createElement("div")
    Object.assign(p.style, {
      display: "flex", flexDirection: "column", gap: "4px", borderRadius: "2px",
    })
    const h = document.createElement("div")
    h.textContent = heading
    Object.assign(h.style, {
      fontSize: "10px", textTransform: "uppercase", letterSpacing: "0.2em",
      color: HUD.amber, marginBottom: "2px", fontFamily: "Oswald, sans-serif",
    })
    p.setAttribute("role", "group")
    p.setAttribute("aria-label", heading)
    p.appendChild(h)
    // Tracked so layout() can restyle panels built later — the Markers panel
    // only exists once the marker payload has arrived over the socket.
    this.hudPanels = this.hudPanels || []
    this.hudPanels.push(p)
    this.stylePanel(p)
    return p
  },
  // Floating, the panels need their own translucent card to read against the
  // map. Docked in an opaque column they don't — the chrome is just noise.
  stylePanel(p) {
    const docked = this._docked
    Object.assign(p.style, {
      background: docked ? "transparent" : HUD_PANEL_BG,
      border: docked ? "none" : `1px solid ${HUD.line}`,
      backdropFilter: docked ? "none" : "blur(2px)",
      padding: docked ? "0 0 6px" : "7px",
    })
  },
  // Width at which the options column docks beside the map instead of floating
  // over it. Measured on the *host*, not the window: the map panel sits inside
  // a max-w-[1800px] column next to a collapsible nav rail, so window width is
  // a poor proxy for the room the map actually has — a window-level
  // matchMedia would happily dock a 200px column inside a 420px-wide host.
  DOCK_MIN: 720,
  DOCK_WIDTH: 200,

  layout() {
    if (!this.leftStack || !this.viewport) return
    const docked = this.el.clientWidth >= this.DOCK_MIN
    if (docked === this._docked) return
    this._docked = docked

    Object.assign(this.leftStack.style, docked
      ? {
        position: "static", top: "", left: "", flex: `0 0 ${this.DOCK_WIDTH}px`,
        width: `${this.DOCK_WIDTH}px`, maxHeight: "100%", padding: "10px 8px",
        background: HUD.ink950, borderRight: `1px solid ${HUD.line}`,
        // The column is a real scroll container now, so it must opt back in to
        // touch scrolling: the viewport's `touch-action: none` no longer
        // covers it, but an inherited value from an ancestor still would.
        touchAction: "pan-y",
      }
      : {
        position: "absolute", top: "10px", left: "10px", flex: "",
        width: "", maxHeight: "calc(100% - 20px)", padding: "0",
        background: "transparent", borderRight: "none", touchAction: "pan-y",
      })

    ;(this.hudPanels || []).forEach((p) => this.stylePanel(p))
    this.refit()
  },

  toolbar() {
    const bar = document.createElement("div")
    Object.assign(bar.style, {
      position: "absolute", top: "10px", right: "10px",
      display: "flex", gap: "4px", zIndex: "5",
    })
    const zin = hudIconButton("zoom-in", "Zoom in")
    const zout = hudIconButton("zoom-out", "Zoom out")
    const reset = hudIconButton("reset", "Reset view")
    zin.addEventListener("click", () => this.zoomBy(1.3))
    zout.addEventListener("click", () => this.zoomBy(1 / 1.3))
    reset.addEventListener("click", () => this.fit())
    bar.append(zin, zout, reset)
    // First child of the viewport so it precedes the pins in the tab order.
    this.viewport.insertBefore(bar, this.viewport.firstChild)
    this.bar = bar

    this.modeToggle()

    // Floor selector (interactive maps only; tile maps have tile floors).
    const layers = this.hasInteractive() && Array.isArray(this.cfg.layers) ? this.cfg.layers : []
    if (layers.length === 0) return
    const p = this.panel("Floors")
    this.floorButtons = []
    const add = (floorId, label) => {
      const b = document.createElement("button")
      b.type = "button"
      b.textContent = label
      b.classList.add("hud-focus")
      Object.assign(b.style, {
        fontSize: "12px", textAlign: "left", padding: "4px 9px",
        borderRadius: "2px", border: `1px solid ${HUD.line}`,
        cursor: "pointer", whiteSpace: "nowrap", fontFamily: "Oswald, sans-serif",
      })
      b.dataset.floorId = floorId == null ? "" : floorId
      b.dataset.active = (floorId || null) === this.floor ? "1" : "0"
      // The base may still be downloading; enableFloorButtons() releases these.
      if (!this.baseReady) {
        b.disabled = true
        b.setAttribute("aria-disabled", "true")
        b.style.opacity = "0.5"
        b.style.cursor = "not-allowed"
      }
      b.addEventListener("click", () => this.selectFloor(floorId == null ? null : floorId))
      this.styleToggle(b)
      p.appendChild(b)
      this.floorButtons.push(b)
    }
    add(null, "Base")
    layers.forEach((l) => add(l.id || l.svgLayer, l.name || l.id || l.svgLayer))
    this.leftStack.appendChild(p)
  },

  MODE_LABELS: { interactive: "Interactive", "2d": "2D", "3d": "3D" },
  MODE_TITLES: {
    interactive: "Show the interactive map",
    "2d": "Show the flat 2D map",
    "3d": "Show the 3D map",
  },
  variantsFor(mode) {
    return (mode === "2d" || mode === "3d") && Array.isArray(this.variants[mode]) ? this.variants[mode] : []
  },
  // A mode button per available mode — always shown, even a lone "2D",
  // for a consistent GUI. Modes with several renders (e.g. Customs 3D +
  // Dorms) get a caret and a hover/tap dropdown to pick the variant.
  modeToggle() {
    this.modeButtons = []
    this.variantMenus = {}
    // Build in reverse so display order matches this.modes.
    for (let i = this.modes.length - 1; i >= 0; i--) {
      const mode = this.modes[i]
      const list = this.variantsFor(mode)
      const multi = list.length > 1

      const wrap = document.createElement("div")
      Object.assign(wrap.style, { position: "relative", display: "inline-flex" })

      const b = hudButton("", this.MODE_TITLES[mode])
      b.dataset.mode = mode
      b.textContent = this.MODE_LABELS[mode] || mode
      if (multi) {
        const caret = document.createElement("span")
        caret.textContent = "\u25BE"
        Object.assign(caret.style, { fontSize: "10px", marginLeft: "4px", opacity: "0.8" })
        b.appendChild(caret)
      }
      b.addEventListener("click", () => {
        this.setMode(mode)
        if (multi) this.toggleVariantMenu(mode)
      })
      wrap.appendChild(b)

      if (multi) {
        const menu = this.variantMenu(mode, list)
        wrap.appendChild(menu)
        wrap.addEventListener("mouseenter", () => this.openVariantMenu(mode))
        wrap.addEventListener("mouseleave", () => this.closeVariantMenus())
        this.variantMenus[mode] = menu
      }

      this.bar.insertBefore(wrap, this.bar.firstChild)
      this.modeButtons.unshift(b)
    }
    this.updateModeButtons()
  },
  variantMenu(mode, list) {
    const menu = document.createElement("div")
    Object.assign(menu.style, {
      position: "absolute", top: "100%", right: "0", display: "none",
      flexDirection: "column", gap: "2px", background: HUD_MENU_BG,
      border: `1px solid ${HUD.lineStrong}`, borderRadius: "2px", padding: "4px",
      zIndex: "7", minWidth: "128px", backdropFilter: "blur(2px)",
    })
    list.forEach((v, idx) => {
      const item = document.createElement("button")
      item.type = "button"
      item.textContent = v.label || `Variant ${idx + 1}`
      item.dataset.mode = mode
      item.dataset.idx = String(idx)
      Object.assign(item.style, {
        fontSize: "12px", textAlign: "left", padding: "5px 9px", whiteSpace: "nowrap",
        border: "none", borderRadius: "2px", cursor: "pointer",
        background: "transparent", color: HUD.fog, fontFamily: "Oswald, sans-serif",
      })
      item.addEventListener("mouseenter", () => { if (idx !== this.variantIndex[mode]) item.style.background = HUD.ink700 })
      item.addEventListener("mouseleave", () => { if (idx !== this.variantIndex[mode]) item.style.background = "transparent" })
      item.addEventListener("click", (e) => {
        e.stopPropagation()
        this.variantIndex[mode] = idx
        this.closeVariantMenus()
        if (this.mode === mode) this.showImage(mode)
        else this.setMode(mode)
        this.updateVariantMenus()
      })
      menu.appendChild(item)
    })
    return menu
  },
  openVariantMenu(mode) {
    this.closeVariantMenus()
    const menu = this.variantMenus && this.variantMenus[mode]
    if (menu) { menu.style.display = "flex"; this.updateVariantMenus() }
  },
  toggleVariantMenu(mode) {
    const menu = this.variantMenus && this.variantMenus[mode]
    if (!menu) return
    const open = menu.style.display !== "none"
    this.closeVariantMenus()
    if (!open) { menu.style.display = "flex"; this.updateVariantMenus() }
  },
  closeVariantMenus() {
    if (!this.variantMenus) return
    Object.keys(this.variantMenus).forEach((m) => { this.variantMenus[m].style.display = "none" })
  },
  updateVariantMenus() {
    if (!this.variantMenus) return
    Object.keys(this.variantMenus).forEach((mode) => {
      Array.from(this.variantMenus[mode].children).forEach((item) => {
        const on = Number(item.dataset.idx) === this.variantIndex[mode]
        item.style.background = on ? HUD.amber : "transparent"
        item.style.color = on ? HUD.ink950 : HUD.fog
        item.style.fontWeight = on ? "700" : "500"
      })
    })
  },
  updateModeButtons() {
    if (!this.modeButtons) return
    this.modeButtons.forEach((b) => {
      const on = b.dataset.mode === this.mode
      b.style.background = on ? HUD.amber : HUD.ink850
      b.style.color = on ? HUD.ink950 : HUD.fog
      b.style.fontWeight = on ? "700" : "500"
    })
  },
  setMode(mode) {
    if (mode === this.mode || !this.modes.includes(mode)) return
    this.mode = mode
    this.closePopup()
    const interactive = this.isInteractive()
    if (this.svg) this.svg.style.display = interactive && this.cfg.projection === "svg" ? "block" : "none"
    if (this.tileWrap) this.tileWrap.style.display = interactive && this.cfg.projection === "tile" ? "block" : "none"
    this.layer.style.display = interactive ? "" : "none"
    // Docked, hiding the column changes the flex layout — the viewport grows or
    // shrinks by DOCK_WIDTH — so the camera has to be corrected either way.
    this.leftStack.style.display = interactive ? "" : "none"
    if (interactive) {
      if (this.imageEl) this.imageEl.style.display = "none"
      this.setStatus(null, false)
      this.clearCredit()
      this.sceneW = this.baseW; this.sceneH = this.baseH
      this.fit()
    } else {
      // Now, rather than waiting on the image's load event — that is a frame
      // away at best and on the failure path never arrives.
      this.refit()
      this.showImage(mode)
    }
    this.updateModeButtons()
    this.updateVariantMenus()
  },
  ensureImageEl() {
    if (this.imageEl) return
    const img = document.createElement("img")
    img.alt = ""; img.draggable = false
    Object.assign(img.style, {
      position: "absolute", top: "0", left: "0", display: "none",
      maxWidth: "none", pointerEvents: "none", userSelect: "none",
    })
    img.addEventListener("load", () => {
      if (img.dataset.url !== this._imgUrl) return
      const w = img.naturalWidth || 2000, h = img.naturalHeight || 2000
      img.style.width = `${w}px`; img.style.height = `${h}px`
      if (!this.isInteractive()) {
        img.style.display = "block"; this.setStatus(null, false)
        this.sceneW = w; this.sceneH = h; this.fit()
      }
    })
    img.addEventListener("error", () => {
      if (!this.isInteractive() && img.dataset.url === this._imgUrl) {
        this.setStatus("Map image failed to load.", true)
      }
    })
    this.imageEl = img
    this.content.appendChild(img)
  },
  // Show the current variant of a 2D / 3D static render.
  showImage(mode) {
    this.ensureImageEl()
    const list = Array.isArray(this.variants[mode]) ? this.variants[mode] : []
    const v = list[(this.variantIndex[mode] || 0) % (list.length || 1)]
    if (!v || !v.url) { this.setStatus("No map image available.", true); return }
    this._imgUrl = v.url
    this.imageEl.dataset.url = v.url
    this.imageEl.style.display = "none"
    this.setStatus("Loading map...", true)
    this.imageEl.src = v.url
    this.showCredit(v)
  },

  // Per-render credit. The flat 2D/3D renders are individually authored
  // (re3mr, Jindouz, monkimonkimonk, Lorathor, xTycho, Shebuka), and maps.json
  // names each one — the panel header can only credit the interactive base, so
  // the active render's author is shown over the image itself. Cleared when
  // switching back to the interactive base, which the header already credits.
  //
  // The name links to the author wherever maps.json gives a link. Lighthouse's
  // 2D is the one entry that names an author ("Shebuka & Jindouz") without one,
  // so it stays plain text rather than being sent somewhere invented.
  showCredit(variant) {
    const author = variant && variant.author
    const href = variant && variant.author_link
    if (!this.credit) {
      this.credit = document.createElement("div")
      Object.assign(this.credit.style, {
        position: "absolute", right: "8px", bottom: "8px", zIndex: "5",
        padding: "2px 6px", background: HUD.ink950, opacity: "0.85",
        border: `1px solid ${HUD.line}`, color: HUD.fogDim,
        font: "9px Oswald, sans-serif", letterSpacing: "0.08em",
        // Clickable, unlike the rest of the overlay chrome — isControl() keeps
        // a press here from starting a map pan.
        textTransform: "uppercase", pointerEvents: "auto",
      })
      this.viewport.appendChild(this.credit)
    }
    this.credit.innerHTML = ""
    if (!author) { this.credit.style.display = "none"; return }

    this.credit.appendChild(document.createTextNode("Map by "))
    if (href) {
      const link = document.createElement("a")
      link.href = href
      link.target = "_blank"
      link.rel = "noopener noreferrer"
      link.textContent = author
      link.classList.add("hud-focus")
      Object.assign(link.style, { color: HUD.fog, textDecoration: "none" })
      link.addEventListener("mouseenter", () => { link.style.color = HUD.amber })
      link.addEventListener("mouseleave", () => { link.style.color = HUD.fog })
      this.credit.appendChild(link)
    } else {
      this.credit.appendChild(document.createTextNode(author))
    }
    this.credit.style.display = "block"
  },

  isControl(t) {
    return (this.popup && this.popup.contains(t)) ||
      (this.bar && this.bar.contains(t)) ||
      (this.credit && this.credit.contains(t)) ||
      (this.leftStack && this.leftStack.contains(t))
  },

  selectFloor(floorId) {
    this.floor = floorId || null
    if (this.floorButtons) {
      this.floorButtons.forEach((b) => {
        b.dataset.active = (b.dataset.floorId || null) === (this.floor || null) ? "1" : "0"
        this.styleToggle(b)
      })
    }
    // Selecting a floor before the base has loaded would build its tile grid
    // against an unknown viewBox and then cache the broken result for the rest
    // of the session. The selection is remembered either way — injectSvg() and
    // renderTiles() both call applyFloors() when the base lands.
    if (!this.baseReady) return
    this.applyFloors()
    this.refreshLevels()
    this.position()
  },
  // Floor buttons are painted in mounted(), but an SVG base arrives over the
  // network. They stay disabled until it does.
  enableFloorButtons() {
    if (!this.floorButtons) return
    this.floorButtons.forEach((b) => {
      b.disabled = false
      b.removeAttribute("aria-disabled")
      b.style.opacity = "1"
      b.style.cursor = "pointer"
    })
  },
  floorIds() {
    const layers = Array.isArray(this.cfg.layers) ? this.cfg.layers : []
    return new Set(layers.map((l) => l.id || l.svgLayer))
  },
  // Floors are applied per-layer, not per-map. A layer highlights an SVG <g>
  // OR overlays its own tile pyramid, and the two mix on a single map: Customs'
  // 4th floor and Reserve's upper floors are tile overlays on an SVG base.
  // Dispatching on the map's projection (as this used to) meant those floors
  // could never render.
  applyFloors() {
    this.applySvgFloors()
    this.applyTileFloors()
    this.applyLabels()
  },
  applySvgFloors() {
    if (!this.svg) return
    const ids = this.floorIds()
    Array.from(this.svg.children)
      .filter((n) => n.tagName && n.tagName.toLowerCase() === "g" && n.id)
      .forEach((g) => {
        if (g.id === this.floor) { g.style.display = ""; g.style.opacity = "1" }
        else if (ids.has(g.id)) { g.style.display = "none"; g.style.opacity = "1" }
        else { g.style.display = ""; g.style.opacity = this.floor ? "0.22" : "1" }
      })
  },
  applyTileFloors() {
    const layer = this.layerById(this.floor)
    // A floor with an SVG group is drawn by highlighting that group, so it
    // needs no raster overlay even though upstream also publishes one.
    const needsTiles = layer && layer.tileUrl && !(this.svg && layer.svgLayer)
    if (needsTiles) this.ensureTileWrap()
    if (!this.tileGrids) return
    // Build the selected floor's grid on first use, so a map with many tile
    // floors (Icebreaker has 16) only fetches what's actually viewed.
    if (needsTiles && !this.tileGrids[this.floor]) {
      const g = this.tileGeom || this.layerGeom(layer)
      this.addTileGrid(this.floor, layer.tileUrl, g.ts, g.n, g.z)
    }
    // The level you are NOT on reads back at 0.22, exactly as applySvgFloors()
    // dims unselected <g> groups. Tile bases used to sit at full opacity under
    // the overlay, which is why only tile maps felt like the floor *covered*
    // the map instead of lifting off it. (Upstream does the same thing:
    // `off-level` on the base tile layer's container.)
    const base = this.tileGrids.__base__
    if (base) base.style.opacity = this.floor ? "0.22" : "1"
    Object.keys(this.tileGrids).forEach((key) => {
      if (key === "__base__") return
      this.tileGrids[key].style.display = key === this.floor ? "block" : "none"
    })
  },
  layerById(id) {
    if (!id) return null
    const layers = Array.isArray(this.cfg.layers) ? this.cfg.layers : []
    return layers.find((x) => (x.id || x.svgLayer) === id) || null
  },
  // Tile geometry for a floor overlay on an SVG base map, where the base itself
  // laid out no mosaic and so set no `tileGeom`.
  layerGeom(layer) {
    const z = layer.tileZoom || 0
    const ts = layer.tileSize || 256
    return { z, ts, n: Math.pow(2, z) }
  },
  // SVG base maps never created a tile container, but they can still have tile
  // floor overlays, so make one on demand and size it to the projected space.
  ensureTileWrap() {
    if (this.tileWrap || !this.content) return
    this.tileWrap = document.createElement("div")
    Object.assign(this.tileWrap.style, {
      position: "absolute", top: "0", left: "0", pointerEvents: "none",
    })
    this.content.appendChild(this.tileWrap)
    this.tileGrids = this.tileGrids || {}
    this.sizeTileWrap()
  },
  // Sized separately from creation because an SVG base map can create the wrap
  // (for a tile floor overlay) before injectSvg() has established baseW/baseH.
  // It used to write "undefinedpx" in that window and, since the wrap is
  // cached, never correct itself.
  sizeTileWrap() {
    if (!this.tileWrap || !this.baseW) return
    this.tileWrap.style.width = `${this.baseW}px`
    this.tileWrap.style.height = `${this.baseH}px`
  },
  onLayer(m, exts) {
    if (!Array.isArray(exts) || exts.length === 0) return true
    if (m.y == null) return true
    for (const ext of exts) {
      const h = ext.height
      if (!h) continue
      if (m.y >= h[0] && m.y < h[1]) {
        if (!ext.bounds) return true
        for (const b of ext.bounds) {
          const x0 = b[0][0], z0 = b[0][1], x1 = b[1][0], z1 = b[1][1]
          if (m.x >= Math.min(x0, x1) && m.x <= Math.max(x0, x1) &&
              m.z >= Math.min(z0, z1) && m.z <= Math.max(z0, z1)) return true
        }
      }
    }
    return false
  },
  // The single floor a marker belongs to (its layer id), or null for the
  // base/ground level. A marker is claimed by the first floor whose height
  // (and, when the extent carries them, x/z bounds) contains it; anything no
  // floor claims lives on the base level. This partitions every marker onto
  // exactly one level, so each shows at full opacity on exactly one
  // selection — and never gets stuck dimmed on every floor (which happened
  // when a marker fell in two floors' extents, or outside the base extent).
  assignedFloor(m) {
    // Without a planar position or a height we can't place it on a floor, so
    // it lives on the base level (shown by default, never stuck dimmed).
    if (m.x == null || m.z == null || m.y == null) return null
    const layers = Array.isArray(this.cfg.layers) ? this.cfg.layers : []
    for (const l of layers) {
      const exts = Array.isArray(l.extents) ? l.extents : []
      if (exts.length && this.onLayer(m, exts)) return l.id || l.svgLayer
    }
    return null
  },
  onActiveLevel(m) {
    return this.assignedFloor(m) === (this.floor || null)
  },
  refreshLevels() {
    if (!this.pins) return
    this.pins.forEach((p) => { p._off = p._m ? !this.onActiveLevel(p._m) : false })
  },

  loadSvg() {
    const url = this.cfg.svgUrl
    if (!url) { this.setStatus("No map available.", true); return }
    fetch(url, { signal: this.abort.signal, credentials: "same-origin" })
      .then((r) => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.text() })
      .then((t) => this.injectSvg(t))
      .catch((err) => { if (err && err.name === "AbortError") return; this.setStatus("Map failed to load.", true) })
  },
  injectSvg(text) {
    const doc = new DOMParser().parseFromString(text, "image/svg+xml")
    const svg = doc.querySelector("svg")
    if (!svg) { this.setStatus("Map failed to load.", true); return }
    const vb = (svg.getAttribute("viewBox") || "").split(/[ ,]+/).map(Number)
    this.vbW = vb.length === 4 && vb[2] > 0 ? vb[2] : svg.clientWidth || 1000
    this.vbH = vb.length === 4 && vb[3] > 0 ? vb[3] : svg.clientHeight || 1000
    svg.removeAttribute("width"); svg.removeAttribute("height")
    Object.assign(svg.style, {
      display: this.isInteractive() ? "block" : "none",
      width: `${this.vbW}px`, height: `${this.vbH}px`,
    })
    this.svg = svg
    this.content.appendChild(svg)
    this.baseW = this.vbW; this.baseH = this.vbH
    this.sceneW = this.vbW; this.sceneH = this.vbH
    this.baseReady = true
    // A floor selected while this was still in flight left a wrap with no size
    // and a grid with no overlay transform. Both are repaired here.
    this.sizeTileWrap()
    this.reapplyTileOverlays()
    this.enableFloorButtons()
    this.applyFloors()
    this.renderData()
    if (this.isInteractive()) { this.setStatus(null, false); this.fit() }
  },

  // Tile-pyramid base: a full 2^tileZoom mosaic placed in the same
  // projected space as the markers. tarkov.dev serves a standard
  // 2^z x 2^z grid where the map fits in tile (0,0) at z=0, so tile
  // (tx,ty) sits at pixel (tx*tileSize, ty*tileSize) and markers land at
  // 2^tileZoom * project(x,z). Missing edge tiles (404) simply vanish.
  renderTiles() {
    const z = this.cfg.tileZoom || 0
    const ts = this.cfg.tileSize || 256
    const n = Math.pow(2, z)
    this.baseW = ts * n; this.baseH = ts * n
    this.sceneW = this.baseW; this.sceneH = this.baseH
    this.tileGeom = { z, ts, n }

    this.tileWrap = document.createElement("div")
    Object.assign(this.tileWrap.style, {
      position: "absolute", top: "0", left: "0",
      width: `${this.baseW}px`, height: `${this.baseH}px`,
      display: this.isInteractive() ? "block" : "none",
    })
    this.content.appendChild(this.tileWrap)

    this.tileGrids = {}
    // Base floor now; upper floors (e.g. The Lab's 2nd level) are built
    // lazily on first selection to keep the initial tile count down.
    this.addTileGrid("__base__", this.cfg.tileUrl, ts, n, z)

    // Synchronous for a tile base, but the flag is the one invariant the floor
    // buttons and the marker render both gate on, so set it here too.
    this.baseReady = true
    this.enableFloorButtons()
    this.applyFloors()

    if (this.isInteractive()) this.setStatus(null, false)
    this.renderData()
    if (this.isInteractive()) this.fit()
  },
  // Map tile-mosaic pixels into SVG scene pixels, for a raster floor overlaid
  // on a vendored SVG base (Customs' 4th floor, Reserve's 2nd-5th).
  //
  // `project()` yields zoom-0 tile pixels, so a point q sits at mosaic pixel
  // q * 2^z, while the SVG normalizes the same q into viewBox pixels via
  // `boxExt`. Composing the two gives an affine transform:
  //   scene = (vbW / (2^z * spanX)) * p  -  vbW * minX / spanX
  tileOverlayTransform(z) {
    if (this.cfg.projection === "tile") return null
    if (!this.boxExt || !this.vbW) return null
    const { minX, maxX, minY, maxY } = this.boxExt
    const s = Math.pow(2, z)
    const spanX = maxX - minX, spanY = maxY - minY
    const sx = this.vbW / (s * spanX), sy = this.vbH / (s * spanY)
    const tx = (-this.vbW * minX) / spanX, ty = (-this.vbH * minY) / spanY
    return `translate(${tx}px, ${ty}px) scale(${sx}, ${sy})`
  },
  // Belt and braces for the gate in selectFloor(): a grid built before the SVG
  // base landed has no overlay transform, and grids are memoised, so without
  // this it would stay misplaced for the whole session.
  reapplyTileOverlays() {
    if (!this.tileGrids) return
    Object.values(this.tileGrids).forEach((grid) => {
      if (grid.dataset.needsOverlay !== "1") return
      const t = this.tileOverlayTransform(Number(grid.dataset.overlayZ) || 0)
      if (!t) return
      grid.style.transformOrigin = "0 0"
      grid.style.transform = t
      delete grid.dataset.needsOverlay
    })
  },
  addTileGrid(key, template, ts, n, z) {
    const grid = document.createElement("div")
    Object.assign(grid.style, {
      position: "absolute", top: "0", left: "0",
      width: `${ts * n}px`, height: `${ts * n}px`,
      display: key === "__base__" ? "block" : "none",
    })
    grid.dataset.overlayZ = String(z)
    const overlay = this.tileOverlayTransform(z)
    if (overlay) { grid.style.transformOrigin = "0 0"; grid.style.transform = overlay }
    // Wanted an overlay transform but couldn't compute one yet (no viewBox);
    // flagged so reapplyTileOverlays() can repair it once the SVG is in.
    else if (this.cfg.projection !== "tile") grid.dataset.needsOverlay = "1"
    for (let ty = 0; ty < n; ty++) {
      for (let tx = 0; tx < n; tx++) {
        const img = document.createElement("img")
        img.src = template.replace("{z}", z).replace("{x}", tx).replace("{y}", ty)
        img.alt = ""; img.draggable = false; img.loading = "lazy"
        Object.assign(img.style, {
          position: "absolute", left: `${tx * ts}px`, top: `${ty * ts}px`,
          width: `${ts}px`, height: `${ts}px`, pointerEvents: "none", userSelect: "none",
        })
        img.addEventListener("error", () => { img.style.display = "none" }, { once: true })
        grid.appendChild(img)
      }
    }
    this.tileWrap.appendChild(grid)
    this.tileGrids[key] = grid
  },

  apply() {
    const { scale, tx, ty } = this.cam
    // Pan lives on the content wrapper; zoom is applied per base layer.
    // The SVG is *resized* (not GPU-scaled) so vectors re-rasterize crisp
    // at every zoom instead of blurring a cached texture. Raster bases
    // (tiles / static images) scale via transform — they blur past their
    // native resolution, same as any bitmap.
    this.content.style.transform = `translate(${tx}px, ${ty}px)`
    this.applyScale(scale)
    this.position()
  },
  applyScale(scale) {
    if (this.svg) {
      this.svg.style.width = `${this.vbW * scale}px`
      this.svg.style.height = `${this.vbH * scale}px`
    }
    if (this.tileWrap) {
      this.tileWrap.style.transformOrigin = "0 0"
      // Composed into the one transform rather than written separately: this
      // runs on every pan and zoom, so a second write would be clobbered. The
      // translate brings the rotated square back into [0, baseW], matching the
      // mapping in toScene(). Floor grids are children, so they follow.
      this.tileWrap.style.transform = this.viewRotated()
        ? `scale(${scale}) translate(0px, ${this.baseW}px) rotate(-90deg)`
        : `scale(${scale})`
    }
    if (this.imageEl) {
      this.imageEl.style.transformOrigin = "0 0"
      this.imageEl.style.transform = `scale(${scale})`
    }
  },
  clamp(s) { const f = this.cam.fit || 1; return Math.min(f * 24, Math.max(f * 0.5, s)) },
  fit() {
    const sw = this.sceneW, sh = this.sceneH
    if (!sw || !sh) return
    const w = this.viewport.clientWidth, h = this.viewport.clientHeight
    const f = Math.min(w / sw, h / sh)
    this.cam.fit = f; this.cam.scale = f
    this.cam.tx = (w - sw * f) / 2; this.cam.ty = (h - sh * f) / 2
    this.apply()
  },
  // Recompute after any change to the viewport box (a resize, or the options
  // column docking / undocking). If the user hasn't zoomed, re-centre as
  // before; if they have, keep their camera but refresh cam.fit anyway —
  // clamp() derives BOTH zoom bounds from it, so a stale value leaves the
  // zoom-out button unable to reach the fitted scale.
  refit() {
    if (!this.sceneW || !this.sceneH || !this.viewport) return
    if (Math.abs(this.cam.scale - this.cam.fit) < 1e-6) return this.fit()
    const w = this.viewport.clientWidth, h = this.viewport.clientHeight
    if (!w || !h) return
    this.cam.fit = Math.min(w / this.sceneW, h / this.sceneH)
    this.cam.scale = this.clamp(this.cam.scale)
    this.apply()
  },
  zoomAt(next, cx, cy) {
    const rect = this.viewport.getBoundingClientRect()
    const px = cx == null ? rect.width / 2 : cx - rect.left
    const py = cy == null ? rect.height / 2 : cy - rect.top
    const s = this.clamp(next)
    const { scale, tx, ty } = this.cam
    const wx = (px - tx) / scale, wy = (py - ty) / scale
    this.cam.scale = s; this.cam.tx = px - wx * s; this.cam.ty = py - wy * s
    this.apply()
  },
  zoomBy(f) { this.zoomAt(this.cam.scale * f, null, null) },
  panBy(dx, dy) { this.cam.tx += dx; this.cam.ty += dy; this.apply() },

  bindInput() {
    const opts = { signal: this.abort.signal }
    this.viewport.addEventListener("wheel", (e) => {
      if (!this.sceneW) return
      // Docked, the options column isn't a viewport descendant so this never
      // fires for it; floating, this guard is what lets a long marker list
      // scroll instead of zooming the map. Either way it still covers the
      // toolbar, the popup and an open variant menu, which live in here.
      if (this.isControl(e.target)) return
      e.preventDefault()
      this.zoomAt(this.cam.scale * (e.deltaY < 0 ? 1.12 : 1 / 1.12), e.clientX, e.clientY)
    }, { passive: false, signal: this.abort.signal })

    this.viewport.addEventListener("pointerdown", (e) => {
      if (!this.sceneW) return
      if (this.isControl(e.target)) return
      this.closePopup()
      this.dragMoved = false
      this.dragOrigin = { x: e.clientX, y: e.clientY }
      if (this.layer && this.layer.contains(e.target)) return
      this.viewport.setPointerCapture(e.pointerId)
      this.pointers.set(e.pointerId, { x: e.clientX, y: e.clientY })
      this.viewport.style.cursor = "grabbing"
      if (this.pointers.size === 2) this.pinch = this.pinchDist()
    }, opts)

    this.viewport.addEventListener("pointermove", (e) => {
      if (!this.pointers.has(e.pointerId)) return
      const prev = this.pointers.get(e.pointerId)
      this.pointers.set(e.pointerId, { x: e.clientX, y: e.clientY })
      if (this.pointers.size === 1) {
        if (this.dragOrigin && Math.hypot(e.clientX - this.dragOrigin.x, e.clientY - this.dragOrigin.y) > 5) this.dragMoved = true
        this.cam.tx += e.clientX - prev.x; this.cam.ty += e.clientY - prev.y
        this.apply()
      } else if (this.pointers.size === 2) {
        const d = this.pinchDist(), mid = this.pinchMid()
        if (this.pinch > 0 && d > 0) this.zoomAt(this.cam.scale * (d / this.pinch), mid.x, mid.y)
        this.pinch = d
      }
    }, opts)

    const end = (e) => {
      if (!this.pointers.has(e.pointerId)) return
      this.pointers.delete(e.pointerId)
      if (this.pointers.size < 2) this.pinch = 0
      if (this.pointers.size === 0) this.viewport.style.cursor = "grab"
    }
    this.viewport.addEventListener("pointerup", end, opts)
    this.viewport.addEventListener("pointercancel", end, opts)

    // Keyboard equivalents for pan / zoom / reset. Bound on the viewport, so
    // it serves both the map itself and (via bubbling) a focused pin — panning
    // while a pin has focus is natural, and Escape there closes its popup.
    const PAN_STEP = 64
    this.viewport.addEventListener("keydown", (e) => {
      if (!this.sceneW) return
      if (this.isControl(e.target)) return
      if (e.altKey || e.ctrlKey || e.metaKey) return
      const d = e.shiftKey ? PAN_STEP * 4 : PAN_STEP
      switch (e.key) {
        case "ArrowLeft": this.panBy(d, 0); break
        case "ArrowRight": this.panBy(-d, 0); break
        case "ArrowUp": this.panBy(0, d); break
        case "ArrowDown": this.panBy(0, -d); break
        case "+": case "=": this.zoomBy(1.3); break
        case "-": case "_": this.zoomBy(1 / 1.3); break
        case "0": this.fit(); break
        // Let Escape bubble when there's nothing open, so it can still close
        // whatever else the page has going.
        case "Escape": if (!this.activePin) return; this.closePopup(); break
        default: return
      }
      e.preventDefault()
    }, opts)

    if (typeof ResizeObserver !== "undefined") {
      // Observes the host, not the viewport: the host's box is set entirely by
      // its parent and never by our own mutations, so re-styling the column
      // inside the callback can't feed back into another observation.
      this.ro = new ResizeObserver(() => { this.layout(); this.refit() })
      this.ro.observe(this.el)
      this.abort.signal.addEventListener("abort", () => this.ro.disconnect())
    }
  },
  pinchDist() {
    const p = Array.from(this.pointers.values())
    return p.length < 2 ? 0 : Math.hypot(p[0].x - p[1].x, p[0].y - p[1].y)
  },
  pinchMid() {
    const p = Array.from(this.pointers.values())
    return p.length < 2 ? { x: null, y: null } : { x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2 }
  },

  // Marker projection mirrors tarkov.dev's Leaflet CRS exactly: rotate
  // game (x, z) by `rotation`, then apply the affine `transform`
  // [scaleX, marginX, scaleZ, marginZ] (Leaflet negates scaleZ so pixel
  // Y runs downward). `project()` returns transform-native units; the
  // per-projection `toScene()` maps those onto the SVG viewBox or the
  // tile mosaic. Base art and markers share this map, so they align.
  setupProjection() {
    const T = this.cfg.transform
    const a = Array.isArray(T) ? (T[0] || 1) : 1
    const b = Array.isArray(T) ? (T[1] || 0) : 0
    const c = Array.isArray(T) ? -(T[2] || 1) : -1
    const d = Array.isArray(T) ? (T[3] || 0) : 0
    const t = ((this.cfg.rotation || 0) * Math.PI) / 180
    this.T = { a, b, c, d, cos: Math.cos(t), sin: Math.sin(t) }
    // Projected extent of the SVG-overlay box, used to normalize markers
    // into SVG viewBox pixels (tile maps project into mosaic space).
    this.boxExt = this.projectExtent(this.cfg.svgBounds || this.cfg.bounds)
  },
  project(x, z) {
    const { a, b, c, d, cos, sin } = this.T
    const rx = x * cos - z * sin
    const rz = x * sin + z * cos
    return [a * rx + b, c * rz + d]
  },
  projectExtent(box) {
    if (!Array.isArray(box) || box.length !== 2) return null
    const [[x0, z0], [x1, z1]] = box
    const pts = [this.project(x0, z0), this.project(x0, z1), this.project(x1, z0), this.project(x1, z1)]
    const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1])
    const minX = Math.min(...xs), maxX = Math.max(...xs)
    const minY = Math.min(...ys), maxY = Math.max(...ys)
    if (maxX - minX === 0 || maxY - minY === 0) return null
    return { minX, maxX, minY, maxY }
  },
  // Whether this map is displayed rotated. Display-only, and separate from
  // cfg.rotation (which aligns game coords to the art's own orientation).
  viewRotated() { return this.cfg.viewRotation === 90 && this.cfg.projection === "tile" },
  toScene(x, z) {
    if (!this.T) return null
    if (this.cfg.projection === "tile") {
      const s = Math.pow(2, this.cfg.tileZoom || 0)
      const p = this.project(x, z)
      // Rotating here rather than on a container is what keeps markers, labels,
      // popups and culling in step: this is the one place a game coordinate
      // becomes a scene pixel, and pins live in an overlay that is never
      // transformed (so their icons and label text also stay upright).
      // 90 CCW about the centre of the square mosaic: (x, y) -> (y, S - x).
      if (this.viewRotated()) return [p[1] * s, this.baseW - p[0] * s]
      return [p[0] * s, p[1] * s]
    }
    // SVG: normalize the projected point into viewBox pixels.
    if (!this.boxExt || !this.vbW) return null
    const { minX, maxX, minY, maxY } = this.boxExt
    const p = this.project(x, z)
    return [this.vbW * (p[0] - minX) / (maxX - minX), this.vbH * (p[1] - minY) / (maxY - minY)]
  },

  // Room / area names drawn onto the map (Interchange has 77, The Lab 31).
  // These come from the same maps.json as the projection config and were
  // previously discarded entirely, which is why the tile maps in particular
  // read as unlabelled grey shapes.
  renderLabels() {
    const labels = Array.isArray(this.cfg.labels) ? this.cfg.labels : []
    this.labelEls = []
    if (!this.T || labels.length === 0 || !this.content) return

    // Labels live in the same screen-space overlay as the pins (zoom is
    // applied per base layer, not to `content`), so they are placed from the
    // camera in `positionLabels()` and keep a constant on-screen size.
    labels.forEach((l) => {
      const pos = Array.isArray(l.position) ? l.position : null
      if (!pos || pos.length < 2) return
      const sc = this.toScene(pos[0], pos[1])
      if (!sc) return

      const el = document.createElement("div")
      el.textContent = l.text
      Object.assign(el.style, {
        position: "absolute", display: "none", whiteSpace: "nowrap",
        transform: "translate(-50%, -50%)", zIndex: "3",
        color: HUD.fog, textTransform: "uppercase", letterSpacing: "0.06em",
        fontFamily: "Oswald, sans-serif", fontSize: "11px",
        textShadow: `0 0 3px ${HUD.ink950}, 0 0 6px ${HUD.ink950}`,
        pointerEvents: "none", userSelect: "none",
      })
      this.layer.appendChild(el)
      // The height-band midpoint stands in for the label's `y`, so the same
      // floor-assignment logic that partitions markers also partitions labels.
      const y =
        typeof l.top === "number" && typeof l.bottom === "number"
          ? (l.top + l.bottom) / 2
          : null
      this.labelEls.push({ el, m: { x: pos[0], z: pos[1], y }, sx: sc[0], sy: sc[1] })
    })

    this.applyLabels()
    this.positionLabels()
  },
  // Labels belong to a floor the same way markers do; on any other floor they
  // are hidden rather than dimmed, since overlapping text is unreadable.
  applyLabels() {
    if (!this.labelEls) return
    this.labelEls.forEach((rec) => { rec._off = !this.onActiveLevel(rec.m) })
    this.positionLabels()
  },
  // Placed from the camera like pins, and culled off-viewport. Labels are
  // hidden below a zoom threshold, where they'd overlap into noise.
  positionLabels() {
    if (!this.labelEls || !this.labelEls.length) return
    if (!this.isInteractive()) {
      this.labelEls.forEach((rec) => { rec.el.style.display = "none" })
      return
    }
    const { scale, tx, ty } = this.cam
    const w = this.viewport.clientWidth, h = this.viewport.clientHeight
    const legible = scale >= (this.cam.fit || 1) * 1.15
    this.labelEls.forEach((rec) => {
      if (rec._off || !legible) { rec.el.style.display = "none"; return }
      const x = tx + rec.sx * scale, y = ty + rec.sy * scale
      if (x < -80 || y < -20 || x > w + 80 || y > h + 20) { rec.el.style.display = "none"; return }
      rec.el.style.display = "block"
      rec.el.style.left = `${x}px`
      rec.el.style.top = `${y}px`
    })
  },

  renderMarkers() {
    const markers = Array.isArray(this.cfg.markers) ? this.cfg.markers : []
    this.pins = []
    if (!this.T || markers.length === 0) return
    markers.forEach((m) => {
      const sc = this.toScene(m.x, m.z)
      if (!sc) return
      const pin = this.makePin(m)
      pin._sx = sc[0]; pin._sy = sc[1]
      this.layer.appendChild(pin)
      this.pins.push(pin)
    })
    this.markerToggles()
    this.refreshLevels()
    this.position()
  },
  // Layer descriptors as sent by the server, in panel order.
  markerTypes() {
    return Array.isArray(this.cfg.markerTypes) ? this.cfg.markerTypes : []
  },
  markerType(type) {
    if (!this._typeIndex) {
      this._typeIndex = new Map(this.markerTypes().map((d) => [d.type, d]))
    }
    return this._typeIndex.get(type)
  },
  markerIconFor(type) {
    const own = this.markerType(type)
    return (own && own.icon) || MARKER_FALLBACK_ICON
  },
  markerLabelFor(type) {
    const d = this.markerType(type)
    return (d && d.label) || null
  },
  markerToggles() {
    if (!this.leftStack || !this.pins || this.pins.length === 0) return
    const present = new Set(this.pins.map((p) => p._type))
    // The server derives the descriptors from the same filtered marker list,
    // so this intersection is normally a no-op — it is a cheap guard against a
    // stale or malformed payload leaving a toggle with nothing behind it.
    const cats = this.markerTypes().filter((c) => present.has(c.type))
    if (cats.length === 0) return
    const p = this.panel("Markers")
    cats.forEach((cat) => {
      const b = document.createElement("button")
      b.type = "button"
      b.classList.add("hud-focus")
      Object.assign(b.style, {
        display: "flex", alignItems: "center", gap: "6px", fontSize: "12px",
        textAlign: "left", padding: "4px 9px", borderRadius: "2px",
        border: `1px solid ${HUD.line}`, cursor: "pointer", whiteSpace: "nowrap",
        fontFamily: "Oswald, sans-serif",
      })
      const icon = document.createElement("img")
      icon.src = this.markerIconFor(cat.type); icon.alt = ""; icon.draggable = false
      Object.assign(icon.style, { width: "14px", height: "14px", objectFit: "contain" })
      const span = document.createElement("span")
      span.textContent = cat.label
      b.append(icon, span)
      b.dataset.markerType = cat.type
      // Apply a category's default visibility once per session, not on every
      // re-render: a LiveView reconnect re-sends the payload, and re-seeding
      // would silently switch the user's toggles back off.
      this._defaulted = this._defaulted || new Set()
      if (!this._defaulted.has(cat.type)) {
        this._defaulted.add(cat.type)
        if (cat.hidden) this.hidden.add(cat.type)
      }
      b.dataset.active = this.hidden.has(cat.type) ? "0" : "1"
      b.addEventListener("click", () => this.toggleType(b))
      this.styleToggle(b)
      p.appendChild(b)
    })
    this._markerPanel = p
    this.leftStack.appendChild(p)
  },
  toggleType(b) {
    const type = b.dataset.markerType
    const on = b.dataset.active === "1"
    b.dataset.active = on ? "0" : "1"
    this.styleToggle(b)
    if (on) { this.hidden.add(type); if (this.activePin && this.activePin._type === type) this.closePopup() }
    else this.hidden.delete(type)
    this.position()
  },
  styleToggle(b) {
    const on = b.dataset.active === "1"
    // State was conveyed by fill colour alone, which a screen reader can't see
    // and a colour-blind user can barely distinguish.
    b.setAttribute("aria-pressed", on ? "true" : "false")
    b.style.background = on ? HUD.amber : HUD.ink850
    b.style.color = on ? HUD.ink950 : HUD.fog
    b.style.fontWeight = on ? "700" : "500"
  },
  makePin(m) {
    const pin = document.createElement("button")
    pin.type = "button"
    // The label used to live only on `title`, on a button whose sole child is
    // an `alt=""` image — assistive tech often suppresses that, leaving the pin
    // nameless. markerLabelFor() gives the generic pins ("Landmine", "Scav
    // spawn") a name even when the marker itself carries none.
    const name = m.label || this.markerLabelFor(m.type) || "Map marker"
    pin.title = name
    pin.setAttribute("aria-label", name)
    pin.setAttribute("aria-haspopup", "dialog")
    pin.setAttribute("aria-expanded", "false")
    pin.classList.add("hud-focus")
    pin._type = m.type; pin._m = m
    Object.assign(pin.style, {
      position: "absolute", width: "26px", height: "26px",
      marginLeft: "-13px", marginTop: "-13px", padding: "0",
      border: "none", background: "none", lineHeight: "0",
      cursor: "pointer", pointerEvents: "auto", display: "none",
    })
    const img = document.createElement("img")
    img.src = this.markerIconFor(m.type); img.alt = ""; img.draggable = false
    Object.assign(img.style, {
      width: "100%", height: "100%", objectFit: "contain",
      filter: "drop-shadow(0 1px 2px rgba(0,0,0,0.8))", pointerEvents: "none",
    })
    pin.appendChild(img)
    pin.addEventListener("click", (e) => { e.stopPropagation(); if (this.dragMoved) return; this.openPopup(m, pin) })
    return pin
  },
  position() {
    if (!this.isInteractive()) return
    this.positionLabels()
    if (!this.pins || this.pins.length === 0) return
    const { scale, tx, ty } = this.cam
    const w = this.viewport.clientWidth, h = this.viewport.clientHeight
    this.pins.forEach((pin) => {
      if (this.hidden.has(pin._type)) { this.cullPin(pin); return }
      const x = tx + pin._sx * scale, y = ty + pin._sy * scale
      if (x < -20 || y < -20 || x > w + 20 || y > h + 20) { this.cullPin(pin) }
      else {
        pin.style.display = "block"
        pin.style.left = `${x}px`; pin.style.top = `${y}px`
        pin.style.opacity = pin._off ? "0.22" : "1"
      }
    })
    if (this.activePin) this.placePopup()
  },
  // `display: none` drops a pin out of the tab order, so culling the one that
  // holds focus would silently dump the user on <body>. Hand focus back to the
  // map, and drop a popup that would otherwise hang at a stale position.
  cullPin(pin) {
    if (document.activeElement === pin) this.viewport.focus()
    if (pin === this.activePin) this.closePopup()
    pin.style.display = "none"
  },
  makePopup() {
    const pop = document.createElement("div")
    Object.assign(pop.style, {
      position: "absolute", display: "none", maxWidth: "240px", zIndex: "6",
      transform: "translate(-50%, calc(-100% - 12px))",
      background: HUD.ink850, border: `1px solid ${HUD.lineStrong}`,
      borderRadius: "2px", padding: "9px 11px", color: HUD.fog,
      fontSize: "13px", lineHeight: "1.35",
      boxShadow: "0 6px 18px rgba(0,0,0,0.6)", pointerEvents: "auto",
    })
    pop.setAttribute("role", "dialog")
    // Not modal: the map stays live behind it, and it closes on any map click.
    pop.setAttribute("aria-modal", "false")
    pop.tabIndex = -1
    pop.addEventListener("pointerdown", (e) => e.stopPropagation())
    return pop
  },
  openPopup(m, pin) {
    this.popup.innerHTML = ""
    const title = document.createElement("div")
    title.id = "tac-popup-title"
    title.textContent = m.label || ""
    Object.assign(title.style, { fontWeight: "600", color: HUD.fog, fontFamily: "Oswald, sans-serif", textTransform: "uppercase", letterSpacing: "0.04em" })
    this.popup.appendChild(title)
    this.popup.setAttribute("aria-labelledby", title.id)

    // The layer this pin belongs to, so a boss pin naming three bosses still
    // says what kind of thing it is.
    const kind = this.markerLabelFor(m.type)
    if (kind && kind !== m.label) {
      const sub = document.createElement("div")
      sub.textContent = kind
      Object.assign(sub.style, { marginTop: "2px", color: HUD.fogDim, fontSize: "11px" })
      this.popup.appendChild(sub)
    }

    if (m.href) {
      const link = document.createElement("a")
      // Every href is in-app (/items?q=\u2026 or /maps/:slug), so this is a
      // LiveView navigation \u2014 it used to open a new tab and cold-load the app.
      link.href = m.href
      link.setAttribute("data-phx-link", "redirect")
      link.setAttribute("data-phx-link-state", "push")
      link.textContent = m.type === "transit" ? "Go to map \u2192" : "View in Items \u2192"
      link.classList.add("hud-focus")
      Object.assign(link.style, { display: "inline-block", marginTop: "5px", color: HUD.amber, textDecoration: "none", fontSize: "12px" })
      this.popup.appendChild(link)
    }

    const close = document.createElement("button")
    close.type = "button"
    close.textContent = "\u00d7"
    close.setAttribute("aria-label", "Close")
    close.classList.add("hud-focus")
    Object.assign(close.style, {
      position: "absolute", top: "2px", right: "4px", padding: "0 4px",
      border: "none", background: "none", color: HUD.fogDim,
      fontSize: "15px", lineHeight: "1", cursor: "pointer",
    })
    close.addEventListener("click", () => this.closePopup())
    this.popup.appendChild(close)

    if (this.activePin) this.activePin.setAttribute("aria-expanded", "false")
    this.activePin = pin
    pin.setAttribute("aria-expanded", "true")
    this.popup.style.display = "block"
    this.placePopup()
    // Focus moves in so Tab reaches the link and the close button, and so
    // Escape has something to return focus from.
    this.popup.focus({ preventScroll: true })
  },
  placePopup() {
    if (!this.activePin) return
    this.popup.style.left = this.activePin.style.left
    this.popup.style.top = this.activePin.style.top
  },
  closePopup() {
    if (!this.popup) return
    const pin = this.activePin
    // Checked before hiding: closePopup() also fires on any pointerdown over
    // the map, and yanking focus back to a pin then would be worse than
    // leaving it where the user put it.
    const hadFocus = this.popup.contains(document.activeElement)
    this.popup.style.display = "none"
    this.activePin = null
    if (!pin) return
    pin.setAttribute("aria-expanded", "false")
    if (hadFocus && pin.style.display !== "none") pin.focus({ preventScroll: true })
  },
}

// =============================================================================
// LEVEL INPUT - instant client-side cap for the editable PMC level field.
// The server (OperatorState) is the source of truth and re-clamps, but this
// keeps the typed value from ever visibly exceeding `max` (e.g. typing "100"
// snaps to "79" immediately, before the debounced change reaches the server).
// =============================================================================
const LevelInput = {
  mounted() {
    this.max = parseInt(this.el.getAttribute("max") || "79", 10)
    this.cap = () => {
      if (this.el.value === "") return
      const n = parseInt(this.el.value, 10)
      if (!Number.isNaN(n) && n > this.max) this.el.value = String(this.max)
    }
    this.el.addEventListener("input", this.cap)
  },
  updated() { this.cap && this.cap() },
}

// =============================================================================
// NUMBER CAP - instant client-side clamp for a decimal numeric field, capping
// BOTH ends to the element's min/max (e.g. scav karma -6.00..+6.00). Like
// LevelInput but float-aware and two-sided: typing "9" snaps to "6", "-9" to
// "-6", before the debounced change reaches the server (which re-clamps too).
// =============================================================================
const NumberCap = {
  mounted() {
    const min = this.el.getAttribute("min")
    const max = this.el.getAttribute("max")
    this.min = min === null ? -Infinity : parseFloat(min)
    this.max = max === null ? Infinity : parseFloat(max)
    this.cap = () => {
      const v = this.el.value
      if (v === "" || v === "-" || v === ".") return
      const n = parseFloat(v)
      if (Number.isNaN(n)) return
      if (n > this.max) this.el.value = String(this.max)
      else if (n < this.min) this.el.value = String(this.min)
    }
    this.el.addEventListener("input", this.cap)
  },
  updated() { this.cap && this.cap() },
}

// =============================================================================
// KARMA SLIDER - the scav-karma control in the left rail. A native range input
// drives the server `set_scav_karma` event (throttled by phx-throttle on the
// input; the server clamps + persists), while this hook paints the instant
// visuals: the sign-based fill (green right of centre for positive karma, rust
// left of it for negative) and the numeric readout. It reads straight off the
// input's value, so `updated()` re-syncs to whatever the server rendered -
// keeping the client paint and the server (source-of-truth) value in lockstep.
// =============================================================================
// The readout colour classes (kept in sync with `karma_color/1` server-side).
const KARMA_CLASSES = ["text-go", "text-rust", "text-fog-100"]

const KarmaSlider = {
  mounted() {
    this.range = this.el.querySelector("[data-karma-input]")
    this.number = this.el.querySelector("[data-karma-number]")
    this.fill = this.el.querySelector("[data-karma-fill]")
    if (!this.range) return

    this.min = parseFloat(this.range.min)
    this.max = parseFloat(this.range.max)
    if (Number.isNaN(this.min)) this.min = -6
    if (Number.isNaN(this.max)) this.max = 6

    this.clamp = (n) => Math.min(this.max, Math.max(this.min, n))
    this.round2 = (n) => Math.round(n * 100) / 100

    // Paint the fill bar from a value: grows from centre (zero) out to the
    // thumb, coloured by sign.
    this.paintFill = (n) => {
      if (!this.fill || Number.isNaN(n)) return
      const span = this.max - this.min || 1
      const pct = ((n - this.min) / span) * 100
      if (n > 0) {
        this.fill.style.left = "50%"
        this.fill.style.right = `${100 - pct}%`
        this.fill.style.background = "var(--color-go)"
      } else if (n < 0) {
        this.fill.style.left = `${pct}%`
        this.fill.style.right = "50%"
        this.fill.style.background = "var(--color-rust)"
      } else {
        this.fill.style.left = "50%"
        this.fill.style.right = "50%"
        this.fill.style.background = ""
      }
    }

    this.colorize = (el, n) => {
      if (!el) return
      el.classList.remove(...KARMA_CLASSES)
      el.classList.add(n > 0 ? "text-go" : n < 0 ? "text-rust" : "text-fog-100")
    }

    // Apply a value to the visuals and the OTHER control. `skip` names the
    // element the user is actively editing so we never fight their input.
    // Committing the value to the server is the forms' job (phx-change +
    // phx-debounce); this is purely client-side sync + paint, so it never
    // round-trips. The fill is phx-update="ignore", so re-applying here (incl.
    // from updated()) keeps it in sync without morphdom ever wiping it.
    this.apply = (raw, skip) => {
      const n = this.clamp(this.round2(raw))
      if (Number.isNaN(n)) return
      this.paintFill(n)
      if (skip !== "range") this.range.value = n
      if (this.number) {
        if (skip !== "number") this.number.value = n
        this.colorize(this.number, n)
      }
    }

    this.onRange = () => this.apply(parseFloat(this.range.value), "range")
    this.onNumber = () => this.apply(parseFloat(this.number.value), "number")
    this.range.addEventListener("input", this.onRange)
    if (this.number) this.number.addEventListener("input", this.onNumber)

    // Initial paint from the server-rendered range value.
    this.apply(parseFloat(this.range.value))
  },
  updated() {
    if (!this.range) return
    // A server patch morphs the (unfocused) range value to the authoritative
    // :scav_karma. Re-sync from it, but never clobber a field the user is
    // actively editing - just repaint the fill in that case.
    const active = document.activeElement
    if (active === this.range || active === this.number) {
      this.paintFill(this.clamp(this.round2(parseFloat(this.range.value))))
    } else {
      this.apply(parseFloat(this.range.value))
    }
  },
  destroyed() {
    if (this.range && this.onRange) this.range.removeEventListener("input", this.onRange)
    if (this.number && this.onNumber) this.number.removeEventListener("input", this.onNumber)
  },
}

// =============================================================================
// PEN SCALE - hover key for the ammo penetration matrix (C1–C6 cells).
// Replaces the old always-on legend panel: hovering any rating cell pops a
// floating 0–6 effectiveness key (rating, label, and average bullets the
// plate stops) with the hovered cell's own rating row highlighted. The
// content is static reference data and a single tooltip element is reused; it
// is positioned in viewport (fixed) space and appended to <body>, so the
// table's horizontal overflow never clips it.
// =============================================================================
const PEN_SCALE = [
  { rating: 0, color: "#8f342d", label: "Pointless", stopped: "20+" },
  { rating: 1, color: "#8f4b2d", label: "It's possible, but...", stopped: "13 to 20" },
  { rating: 2, color: "#8f632d", label: "Magdump only", stopped: "9 to 13" },
  { rating: 3, color: "#8f7f2d", label: "Slightly effective", stopped: "5 to 9" },
  { rating: 4, color: "#7c8f2d", label: "Effective", stopped: "3 to 5" },
  { rating: 5, color: "#4e8f2d", label: "Very effective", stopped: "1 to 3" },
  { rating: 6, color: "#2d8f41", label: "Usually ignores", stopped: "<1" },
]

const PenScale = {
  mounted() {
    this.tip = this.buildTip()
    document.body.appendChild(this.tip)

    this.onOver = (e) => {
      const cell = e.target.closest && e.target.closest("[data-pen-rating]")
      if (cell && this.el.contains(cell)) this.show(cell)
    }
    this.onOut = (e) => {
      const cell = e.target.closest && e.target.closest("[data-pen-rating]")
      if (!cell) return
      const to = e.relatedTarget
      if (to && cell.contains(to)) return
      this.hide()
    }
    this.onScroll = () => this.hide()

    this.el.addEventListener("mouseover", this.onOver)
    this.el.addEventListener("mouseout", this.onOut)
    window.addEventListener("scroll", this.onScroll, true)
  },
  destroyed() {
    this.el.removeEventListener("mouseover", this.onOver)
    this.el.removeEventListener("mouseout", this.onOut)
    window.removeEventListener("scroll", this.onScroll, true)
    if (this.tip && this.tip.parentNode) this.tip.parentNode.removeChild(this.tip)
  },
  buildTip() {
    const tip = document.createElement("div")
    Object.assign(tip.style, {
      position: "fixed", zIndex: "60", display: "none", maxWidth: "380px",
      background: HUD_MENU_BG, border: `1px solid ${HUD.lineStrong}`,
      borderRadius: "2px", padding: "8px", pointerEvents: "none",
      boxShadow: "0 6px 18px rgba(0,0,0,0.6)", backdropFilter: "blur(2px)",
    })
    const title = document.createElement("div")
    title.textContent = "Penetration vs armor class"
    Object.assign(title.style, {
      fontSize: "10px", textTransform: "uppercase", letterSpacing: "0.2em",
      color: HUD.amber, fontFamily: "Oswald, sans-serif", margin: "0 4px 6px",
    })
    tip.appendChild(title)

    const cols = "22px 1fr auto"
    const head = document.createElement("div")
    Object.assign(head.style, {
      display: "grid", gridTemplateColumns: cols, gap: "10px",
      alignItems: "end", padding: "0 4px 4px",
    })
    const headLabel = document.createElement("span")
    headLabel.textContent = "Effectiveness"
    headLabel.style.gridColumn = "1 / 3"
    const headStopped = document.createElement("span")
    headStopped.textContent = "Avg. bullets stopped"
    ;[headLabel, headStopped].forEach((h) => {
      Object.assign(h.style, {
        color: HUD.fogDim, fontFamily: "Oswald, sans-serif", fontSize: "9px",
        textTransform: "uppercase", letterSpacing: "0.14em",
      })
    })
    headStopped.style.textAlign = "right"
    head.append(headLabel, headStopped)
    tip.appendChild(head)

    this.rows = {}
    PEN_SCALE.forEach((s) => {
      const row = document.createElement("div")
      Object.assign(row.style, {
        display: "grid", gridTemplateColumns: cols, gap: "10px",
        alignItems: "center", padding: "3px 4px", borderRadius: "2px",
      })
      const chip = document.createElement("span")
      chip.textContent = String(s.rating)
      Object.assign(chip.style, {
        display: "inline-flex", alignItems: "center", justifyContent: "center",
        width: "22px", height: "22px", background: s.color, color: "#f3f1e7",
        fontFamily: "JetBrains Mono, monospace", fontSize: "11px",
        border: "1px solid rgba(0,0,0,0.25)",
      })
      const label = document.createElement("span")
      label.textContent = s.label
      Object.assign(label.style, {
        color: "#e7e4d6", fontSize: "12px", lineHeight: "1.25", fontWeight: "600", whiteSpace: "nowrap",
      })
      const stopped = document.createElement("span")
      stopped.textContent = s.stopped
      Object.assign(stopped.style, {
        color: HUD.fog, fontFamily: "JetBrains Mono, monospace", fontSize: "11px",
        whiteSpace: "nowrap", textAlign: "right",
      })
      row.append(chip, label, stopped)
      tip.appendChild(row)
      this.rows[s.rating] = row
    })

    return tip
  },
  show(cell) {
    const rating = cell.getAttribute("data-pen-rating")
    Object.keys(this.rows).forEach((r) => {
      this.rows[r].style.background = r === rating ? "rgba(154,136,102,0.16)" : "transparent"
    })
    this.tip.style.display = "block"
    this.position(cell)
  },
  position(cell) {
    const r = cell.getBoundingClientRect()
    const tw = this.tip.offsetWidth, th = this.tip.offsetHeight
    const m = 8
    let left = Math.max(m, Math.min(r.left + r.width / 2 - tw / 2, window.innerWidth - tw - m))
    let top = r.top - th - m
    if (top < m) top = r.bottom + m
    this.tip.style.left = `${Math.round(left)}px`
    this.tip.style.top = `${Math.round(top)}px`
  },
  hide() { if (this.tip) this.tip.style.display = "none" },
}

// =============================================================================
// FitList - fit a list to the height of the block beside it.
//
// The Tasks detail panel puts the required items in the wide left column and
// the requirements + rewards in the narrow right one. Left alone the item list
// is as tall as its content, so the handful of quests asking for dozens of
// items pushed the objectives - the reason the panel was opened - off the
// screen, while the right column sat half empty next to them.
//
// This hook caps the list at the right column's height and lets the overflow
// scroll, so the two columns end on the same line. It also chooses the column
// count: ONE column while the list fits (the common case by far - most quests
// need four items or fewer, and splitting those into two stubby columns reads
// worse than a short single column), TWO once one column would overrun.
//
// `max-height`, never `height`: a short list keeps its natural size so the
// objectives follow immediately underneath instead of after a manufactured
// void. The cap is rounded DOWN to whole rows, so it never slices a row.
//
// Both values are inline styles, which morphdom clobbers on patch, so
// `updated()` re-applies them - the same reason Shell re-applies the rail
// transform.
//
// What this deliberately does NOT do is watch the neighbouring column for
// changes. It used to, via a ResizeObserver, which meant expanding the
// requirements list in place made the item list grow with it: a click in one
// section resized another, several hundred pixels away, for no reason the
// reader could see. They are independent sections and they now behave like it.
// The trade-off is that the fit reflects the column's height at mount, so an
// expanded requirements list is simply taller than the items beside it - which
// is what the reader just asked for by expanding it.
// =============================================================================
const FIT_LIST_BREAKPOINT = "(min-width: 64rem)" // Tailwind's `lg`
const FIT_LIST_COLUMNS = 2

// Ceiling on the fit, in rows. The list matches its neighbour only while the
// neighbour is shorter than this, so one outlier can't drag it to full height:
// the requirements block is uncapped, and Collector's runs to 71 lines because
// it gates on 70 other quests. Matching that would hand a single quest a
// 1,900px item list. Every other quest's right column is 6-8 rows tall, well
// under the ceiling, so this term changes nothing for them.
const FIT_LIST_MAX_ROWS = 8

const FitList = {
  mounted() {
    this.list = this.el.querySelector("[data-fit-list]")
    const selector = this.el.dataset.fitTo
    this.target = selector ? document.querySelector(selector) : null
    this.mq = window.matchMedia(FIT_LIST_BREAKPOINT)
    this.apply = () => this.fit()

    this.alive = true
    this.mq.addEventListener("change", this.apply)
    window.addEventListener("resize", this.apply)

    // A single re-fit once webfonts land. The neighbouring column's height
    // depends on how its sentences wrap, and that changes when the real font
    // replaces the fallback metrics. One shot, not a running observer, so it
    // can't turn into the "one section resizes another" behaviour above.
    if (document.fonts && document.fonts.ready) {
      document.fonts.ready.then(() => { if (this.alive) this.fit() })
    }

    this.fit()
  },
  updated() { if (this.fit) this.fit() },
  destroyed() {
    this.alive = false
    if (this.mq) this.mq.removeEventListener("change", this.apply)
    window.removeEventListener("resize", this.apply)
  },

  // The height of the block we're matching - its CONTENT height, not its box.
  //
  // The block is a grid item, and a grid item stretches to its row's height by
  // default. The row is as tall as its tallest column, which is the very list
  // we're here to shrink, so `offsetHeight` would measure that list through its
  // own neighbour: a long list makes the row tall, the tall row reports plenty
  // of space, so nothing is ever capped. `lg:self-start` in the template stops
  // the stretch; measuring the content rather than the box means a future style
  // change can't quietly reintroduce the loop.
  targetHeight() {
    const blocks = Array.from(this.target.children).filter((el) => el.offsetParent !== null)
    if (blocks.length === 0) return 0
    const top = this.target.getBoundingClientRect().top
    const bottom = blocks[blocks.length - 1].getBoundingClientRect().bottom
    return Math.max(0, Math.round(bottom - top))
  },

  // One row's outer height, measured rather than assumed so a change to the
  // tile size or row spacing in the template can't silently desync this.
  rowHeight() {
    const row = this.list && this.list.firstElementChild
    if (!row) return 0
    const margin = parseFloat(window.getComputedStyle(row).marginBottom) || 0
    return row.offsetHeight + margin
  },

  // Whatever sits between the top of the section and the top of the scroll box
  // (the "Required items" eyebrow and its gap), so the list's last row lands
  // level with the bottom of the block we're matching rather than below it.
  headerHeight() {
    const section = this.el.closest("[data-fit-section]")
    return section ? Math.max(0, section.offsetHeight - this.el.offsetHeight) : 0
  },

  clear() {
    this.el.style.maxHeight = ""
    if (this.list) this.list.style.gridTemplateColumns = ""
  },

  fit() {
    if (!this.list) return
    // Stacked (mobile) layout: one column, full height, nothing to match.
    if (!this.mq.matches || !this.target) return this.clear()

    const rowH = this.rowHeight()
    const available = this.targetHeight() - this.headerHeight()
    if (rowH <= 0 || available <= 0) return this.clear()

    const rows = Math.min(FIT_LIST_MAX_ROWS, Math.max(1, Math.floor(available / rowH)))
    const count = this.list.children.length
    const columns = count <= rows ? 1 : FIT_LIST_COLUMNS

    this.list.style.gridTemplateColumns = `repeat(${columns}, minmax(0, 1fr))`
    this.el.style.maxHeight = `${Math.min(rows, Math.ceil(count / columns)) * rowH}px`
  },
}

// =============================================================================
// LiveSocket
// =============================================================================
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: {
    ...colocatedHooks,
    Hud, Shell, TacMap, LevelInput, NumberCap, KarmaSlider, PenScale, Backup,
    FitList,
  },
})

// Top loading bar, themed to the HUD gold.
topbar.config({ barColors: { 0: "#9a8866" }, shadowColor: "rgba(0,0,0,0.4)" })
window.addEventListener("phx:page-loading-start", () => topbar.show(300))
window.addEventListener("phx:page-loading-stop", () => topbar.hide())

// Press "/" anywhere (outside a field) to jump to the page's search box - a
// common power-user shortcut on data-heavy sites. We bail when the user is
// already typing in an input/textarea/select/contenteditable so it never
// hijacks normal typing, and we let modified presses (Ctrl+/, ⌘/, etc.)
// through. The search field carries a `data-search-input` marker.
window.addEventListener("keydown", (e) => {
  if (e.key !== "/" || e.ctrlKey || e.metaKey || e.altKey) return
  const t = e.target
  const tag = t && t.tagName
  const typing =
    tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || (t && t.isContentEditable)
  if (typing) return
  const field = document.querySelector("[data-search-input]")
  if (field) {
    e.preventDefault()
    field.focus()
    field.select && field.select()
  }
})

// CSP-safe <img> fallback: a failed `.img-fallback` image is hidden and its
// next sibling (an inline glyph placeholder) revealed. Capture phase because
// resource error events don't bubble.
window.addEventListener("error", (e) => {
  const el = e.target
  if (el && el.tagName === "IMG" && el.classList.contains("img-fallback")) {
    el.style.display = "none"
    const fb = el.nextElementSibling
    if (fb) fb.style.display = "block"
  }
}, true)

// The recovery half of the fallback: when an `.img-fallback` image DOES load,
// re-show it and re-hide the glyph. This makes the handoff self-correcting -
// important for streamed lists (e.g. the Items grid), where LiveView recycles
// a DOM node for a new row and patches only the `src`; the inline
// `display:none` we set on a prior error isn't tracked by morphdom, so without
// this a recovered image would stay hidden behind the placeholder until a full
// reload. Capture phase because `load` doesn't bubble either.
window.addEventListener("load", (e) => {
  const el = e.target
  if (el && el.tagName === "IMG" && el.classList.contains("img-fallback")) {
    el.style.display = ""
    const fb = el.nextElementSibling
    if (fb) fb.style.display = "none"
  }
}, true)

// Re-clicking the nav entry for the page you're already on triggers a
// redundant live navigation - a visible reload with no state change. Cancel
// same-path "redirect" link clicks so the active endpoint is a no-op. Capture
// phase runs before LiveView's own handler; patch links (query-only changes
// like tabs/filters) carry data-phx-link="patch" and are deliberately left
// untouched.
window.addEventListener("click", (e) => {
  const link = e.target.closest && e.target.closest('a[data-phx-link="redirect"]')
  if (!link) return
  try {
    if (new URL(link.href, window.location.origin).pathname === window.location.pathname) {
      e.preventDefault()
      e.stopImmediatePropagation()
    }
  } catch (_e) {}
}, true)

liveSocket.connect()
window.liveSocket = liveSocket

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({ detail: reloader }) => {
    reloader.enableServerLogs()
    let keyDown
    window.addEventListener("keydown", (e) => (keyDown = e.key))
    window.addEventListener("keyup", () => (keyDown = null))
    window.addEventListener("click", (e) => {
      if (keyDown === "c") { e.preventDefault(); e.stopImmediatePropagation(); reloader.openEditorAtCaller(e.target) }
      else if (keyDown === "d") { e.preventDefault(); e.stopImmediatePropagation(); reloader.openEditorAtDef(e.target) }
    }, true)
    window.liveReloader = reloader
  })
}
