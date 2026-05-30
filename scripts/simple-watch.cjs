// Watch NavBot/**/*.lua → bundle → deploy (runs in current terminal, no extra windows)
const { execFile } = require("node:child_process");
const path = require("node:path");
const chokidar = require("chokidar");

const ROOT = process.cwd();
let debounceTimer = null;
let isRunning = false;

function runNode(scriptName) {
  return new Promise((resolve, reject) => {
    execFile(
      process.execPath,
      [path.join(ROOT, "scripts", scriptName)],
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

async function bundleAndDeploy() {
  if (isRunning) {
    return;
  }
  isRunning = true;
  try {
    console.log("Bundling NavBot...");
    await runBundleScript();
    console.log("Deploying to LMAOBox...");
    await runNode("deploy.cjs");
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

console.log("Watching NavBot/**/*.lua (bundle + deploy on save)...");
console.log("Press Ctrl+C to stop.");

chokidar
  .watch(path.join(ROOT, "NavBot", "**", "*.lua"), {
    ignoreInitial: true,
    awaitWriteFinish: { stabilityThreshold: 200, pollInterval: 50 },
  })
  .on("change", (filePath) => scheduleBundle("changed", filePath))
  .on("add", (filePath) => scheduleBundle("added", filePath));

bundleAndDeploy().catch(console.error);
