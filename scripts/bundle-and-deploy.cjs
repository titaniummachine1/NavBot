// Bundle NavBot and copy output to LMAOBox lua folder
const { spawnSync } = require("node:child_process");
const path = require("node:path");

const root = path.join(__dirname, "..");

console.log("");
console.log("========================================");
console.log(" NavBot bundle + deploy");
console.log("========================================");

function runStep(scriptRelativePath) {
  const scriptPath = path.join(root, scriptRelativePath);
  const result = spawnSync(process.execPath, [scriptPath], {
    cwd: root,
    stdio: "inherit",
    windowsHide: true,
  });

  if (result.status !== 0) {
    process.exit(result.status === null ? 1 : result.status);
  }
}

runStep("bundle.js");
runStep("scripts/deploy.cjs");

console.log("========================================");
console.log(" Deploy complete");
console.log("========================================");
console.log("");
