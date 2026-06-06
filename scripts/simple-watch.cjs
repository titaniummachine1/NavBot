// Watch NavBot/**/*.lua → bundle → deploy (fires on every disk write / auto-save)
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const ROOT = path.join(__dirname, "..");
const NAVBOT_DIR = path.join(ROOT, "NavBot");
const BUNDLE_SCRIPT = path.join(ROOT, "scripts", "bundle-and-deploy.cjs");
const DEBOUNCE_MS = 150;

let debounceTimer = null;
let isRunning = false;
let runAgain = false;

function runBundleAndDeploy() {
  console.log("");
  console.log("========================================");
  console.log("[Watch] NavBot bundle + deploy");
  console.log("========================================");

  const result = spawnSync(process.execPath, [BUNDLE_SCRIPT], {
    cwd: ROOT,
    stdio: "inherit",
    windowsHide: true,
  });

  if (result.status !== 0) {
    console.log("========================================");
    console.log("[Watch] FAILED");
    console.log("========================================");
    return false;
  }

  console.log("========================================");
  console.log("[Watch] OK");
  console.log("========================================");
  return true;
}

function flushBundleQueue() {
  if (isRunning) {
    runAgain = true;
    return;
  }

  isRunning = true;
  runBundleAndDeploy();
  isRunning = false;

  if (runAgain) {
    runAgain = false;
    flushBundleQueue();
  }
}

function scheduleBundle(reason, filePath) {
  if (debounceTimer) {
    clearTimeout(debounceTimer);
  }

  debounceTimer = setTimeout(function () {
    debounceTimer = null;
    const rel = path.relative(ROOT, filePath);
    console.log(`[Watch] ${reason}: ${rel}`);
    flushBundleQueue();
  }, DEBOUNCE_MS);
}

function watchDirectory(dir) {
  if (!fs.existsSync(dir)) {
    console.error(`[Watch] Directory missing: ${dir}`);
    process.exit(1);
  }

  fs.watch(dir, { recursive: true }, function (eventType, filename) {
    if (!filename || !filename.endsWith(".lua")) {
      return;
    }
    scheduleBundle(eventType, path.join(dir, filename));
  });
}

console.log("[Watch] NavBot/**/*.lua → bundle + deploy");
console.log("[Watch] Saves (incl. focus-change auto-save) update the .lua on disk.");
console.log("[Watch] Press Ctrl+C to stop.");
console.log("");

watchDirectory(NAVBOT_DIR);
flushBundleQueue();
