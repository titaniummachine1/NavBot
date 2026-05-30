// Watch NavBot/**/*.lua → bundle → deploy (no npm dependencies)
const fs = require("node:fs");
const path = require("node:path");
const { execFile } = require("node:child_process");

const ROOT = process.cwd();
const NAVBOT_DIR = path.join(ROOT, "NavBot");
let debounceTimer = null;
let isRunning = false;

function runBundleScript() {
  return new Promise((resolve, reject) => {
    execFile(
      process.execPath,
      [path.join(ROOT, "bundle.js")],
      { cwd: ROOT },
      (error, stdout, stderr) => {
        if (stdout) process.stdout.write(stdout);
        if (stderr) process.stderr.write(stderr);
        if (error) {
          reject(error);
          return;
        }
        resolve();
      },
    );
  });
}

function runDeploy() {
  return new Promise((resolve, reject) => {
    execFile(
      process.execPath,
      [path.join(ROOT, "scripts", "deploy.cjs")],
      { cwd: ROOT },
      (error, stdout, stderr) => {
        if (stdout) process.stdout.write(stdout);
        if (stderr) process.stderr.write(stderr);
        if (error) {
          reject(error);
          return;
        }
        resolve();
      },
    );
  });
}

async function bundleAndDeploy() {
  if (isRunning) {
    return;
  }
  isRunning = true;
  try {
    console.log("Bundling NavBot...");
    await runBundleScript();
    console.log("Deploying to LMAOBox...");
    await runDeploy();
    console.log("Ready.");
  } catch (error) {
    console.error("bundle/deploy failed:", error.message);
  } finally {
    isRunning = false;
  }
}

function scheduleBundle(reason, filePath) {
  if (debounceTimer) {
    clearTimeout(debounceTimer);
  }
  debounceTimer = setTimeout(() => {
    console.log(`${reason}: ${filePath}`);
    bundleAndDeploy().catch(console.error);
  }, 400);
}

function watchDirectory(dir) {
  if (!fs.existsSync(dir)) {
    console.error(`Directory missing: ${dir}`);
    return;
  }

  fs.watch(dir, { recursive: true }, (eventType, filename) => {
    if (!filename || !filename.endsWith(".lua")) {
      return;
    }
    scheduleBundle(eventType, path.join(dir, filename));
  });
}

console.log("Watching NavBot/**/*.lua (bundle + deploy on save)...");
console.log("Press Ctrl+C to stop.");

watchDirectory(NAVBOT_DIR);
bundleAndDeploy().catch(console.error);
