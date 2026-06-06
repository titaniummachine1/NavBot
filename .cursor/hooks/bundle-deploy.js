#!/usr/bin/env node
// After agent edits NavBot sources, bundle and deploy (stdin = Cursor hook JSON)
const { spawnSync } = require("node:child_process");
const path = require("node:path");

const NAVBOT_LUA = /NavBot[\\/].+\.lua$/i;

function readStdin() {
  return new Promise(function (resolve) {
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", function (chunk) {
      input = input + chunk;
    });
    process.stdin.on("end", function () {
      resolve(input);
    });
  });
}

function shouldBundleForEdit(payload) {
  const filePath = payload.file_path || payload.path || "";
  if (filePath && NAVBOT_LUA.test(filePath)) {
    return true;
  }

  const edits = payload.edits;
  if (Array.isArray(edits)) {
    for (let i = 0; i < edits.length; i++) {
      const editPath = edits[i].file_path || edits[i].path || "";
      if (NAVBOT_LUA.test(editPath)) {
        return true;
      }
    }
  }

  return false;
}

function runBundleDeploy() {
  const root = process.cwd();
  const scriptPath = path.join(root, "scripts", "bundle-and-deploy.cjs");
  spawnSync(process.execPath, [scriptPath], {
    cwd: root,
    stdio: "inherit",
    windowsHide: true,
  });
}

readStdin()
  .then(function (raw) {
    if (!raw || raw.trim() === "") {
      process.exit(0);
      return;
    }

    let payload = {};
    try {
      payload = JSON.parse(raw);
    } catch (_err) {
      process.exit(0);
      return;
    }

    if (!shouldBundleForEdit(payload)) {
      process.exit(0);
      return;
    }

    runBundleDeploy();
    process.exit(0);
  })
  .catch(function () {
    process.exit(0);
  });
