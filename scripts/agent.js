#!/usr/bin/env node
// rebundle-extensions.js
//
// Wipes stale extensions out of every SuperIsland.app bundle on this machine
// and copies the current contents of `Extensions/` back in. Useful when the
// loaded extension set has drifted from what's in this branch (e.g. an
// extension built on another branch is still showing up).
//
// Usage:
//   node scripts/rebundle-extensions.js               # rebundle everything
//   node scripts/rebundle-extensions.js --dry-run     # show what would happen
//   node scripts/rebundle-extensions.js --app PATH    # rebundle a specific .app
//   node scripts/rebundle-extensions.js --clean-installed
//                                                     # also wipe ~/Library/Application Support/SuperIsland/Extensions

"use strict";

const fs   = require("fs");
const path = require("path");
const os   = require("os");
const { execSync } = require("child_process");

const REPO_ROOT       = path.resolve(__dirname, "..");
const SOURCE_EXT_DIR  = path.join(REPO_ROOT, "Extensions");
const APP_SUPPORT_DIR = path.join(os.homedir(), "Library", "Application Support", "SuperIsland", "Extensions");
const DERIVED_DATA    = path.join(os.homedir(), "Library", "Developer", "Xcode", "DerivedData");
const SKIP_FILES      = new Set([".DS_Store", "README.md", "node_modules"]);

const args = process.argv.slice(2);
const dryRun         = args.includes("--dry-run");
const cleanInstalled = args.includes("--clean-installed");
const appFlagIdx     = args.indexOf("--app");
const customAppPath  = appFlagIdx >= 0 ? args[appFlagIdx + 1] : null;

function log(...m)  { console.log(...m); }
function warn(...m) { console.warn("⚠ ", ...m); }
function done(...m) { console.log("✓", ...m); }

function listSourceExtensions() {
  if (!fs.existsSync(SOURCE_EXT_DIR)) {
    throw new Error(`Source Extensions/ not found at ${SOURCE_EXT_DIR}`);
  }
  return fs.readdirSync(SOURCE_EXT_DIR, { withFileTypes: true })
    .filter(d => d.isDirectory() && !SKIP_FILES.has(d.name))
    .map(d => d.name)
    // an extension dir must have a manifest.json
    .filter(name => fs.existsSync(path.join(SOURCE_EXT_DIR, name, "manifest.json")));
}

function findAppBundles() {
  if (customAppPath) {
    const abs = path.resolve(customAppPath);
    return fs.existsSync(abs) ? [abs] : [];
  }

  const found = new Set();

  // 1. Local build/ output of build-dmg.sh
  const localBuild = path.join(REPO_ROOT, "build", "SuperIsland.app");
  if (fs.existsSync(localBuild)) found.add(localBuild);

  // 2. Installed app
  const installed = "/Applications/SuperIsland.app";
  if (fs.existsSync(installed)) found.add(installed);

  // 3. Every Xcode DerivedData build (Debug + Release)
  if (fs.existsSync(DERIVED_DATA)) {
    for (const entry of fs.readdirSync(DERIVED_DATA)) {
      if (!entry.startsWith("SuperIsland-")) continue;
      const products = path.join(DERIVED_DATA, entry, "Build", "Products");
      if (!fs.existsSync(products)) continue;
      for (const cfg of fs.readdirSync(products)) {
        const app = path.join(products, cfg, "SuperIsland.app");
        if (fs.existsSync(app)) found.add(app);
      }
    }
  }

  return [...found];
}

function isWritable(p) {
  try { fs.accessSync(p, fs.constants.W_OK); return true; }
  catch { return false; }
}

function rebundleApp(appPath, sourceNames) {
  const dest = path.join(appPath, "Contents", "Resources", "BundledExtensions");
  log(`\n→ ${appPath}`);

  // Bail early on locked system paths (e.g. /Applications signed by another user).
  const writeProbe = fs.existsSync(dest) ? dest : path.join(appPath, "Contents", "Resources");
  if (!dryRun && !isWritable(writeProbe)) {
    warn(`  not writable (locked by macOS / owned by another user) — skipping`);
    warn(`  to update this one, reinstall the app or run: sudo node ${path.relative(process.cwd(), __filename)} --app ${JSON.stringify(appPath)}`);
    return { ok: false, reason: "not-writable" };
  }

  try {
    if (fs.existsSync(dest)) {
      const existing = fs.readdirSync(dest).filter(n => !SKIP_FILES.has(n));
      const stale    = existing.filter(n => !sourceNames.includes(n));
      if (stale.length) log(`  removing stale: ${stale.join(", ")}`);
      if (dryRun) {
        log(`  (dry-run) would wipe and recreate ${dest}`);
      } else {
        fs.rmSync(dest, { recursive: true, force: true });
      }
    }

    if (!dryRun) fs.mkdirSync(dest, { recursive: true });

    for (const name of sourceNames) {
      const src = path.join(SOURCE_EXT_DIR, name);
      const dst = path.join(dest, name);
      log(`  copying ${name}/`);
      if (dryRun) continue;
      execSync(
        `rsync -a --delete --exclude=node_modules --exclude=.DS_Store ` +
        `${JSON.stringify(src + "/")} ${JSON.stringify(dst + "/")}`
      );
    }

    done(`bundled ${sourceNames.length} extensions into ${path.basename(appPath)}`);
    return { ok: true };
  } catch (err) {
    warn(`  failed: ${err.message}`);
    return { ok: false, reason: "error", error: err };
  }
}

function cleanInstalledExtensions() {
  if (!fs.existsSync(APP_SUPPORT_DIR)) {
    log(`\n(no installed extensions at ${APP_SUPPORT_DIR})`);
    return;
  }
  const entries = fs.readdirSync(APP_SUPPORT_DIR).filter(n => !SKIP_FILES.has(n));
  if (!entries.length) {
    log(`\n(installed extensions dir is empty)`);
    return;
  }
  log(`\n→ ${APP_SUPPORT_DIR}`);
  for (const name of entries) {
    log(`  removing ${name}/`);
    if (!dryRun) fs.rmSync(path.join(APP_SUPPORT_DIR, name), { recursive: true, force: true });
  }
  done(`cleaned ${entries.length} installed extensions`);
}

// ─── main ─────────────────────────────────────────────────────────────────────

const sourceNames = listSourceExtensions();
log(`Source extensions: ${sourceNames.join(", ")}`);
if (dryRun) log("(dry-run — no files will be modified)");

const apps = findAppBundles();
if (!apps.length) {
  warn("No SuperIsland.app bundles found. Build the app first or pass --app <path>.");
  process.exit(1);
}
log(`Found ${apps.length} app bundle(s):`);
apps.forEach(a => log(`  • ${a}`));

let succeeded = 0, skipped = 0, failed = 0;
for (const app of apps) {
  const result = rebundleApp(app, sourceNames);
  if (result.ok) succeeded++;
  else if (result.reason === "not-writable") skipped++;
  else failed++;
}

if (cleanInstalled) cleanInstalledExtensions();

log(`\nSummary: ${succeeded} rebundled, ${skipped} skipped, ${failed} failed.`);
log(dryRun ? "Dry run complete." : "Restart SuperIsland to see the changes.");
process.exit(failed > 0 ? 1 : 0);

