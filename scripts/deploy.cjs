// Copy bundled Lua into LMAOBox folder (no extra windows / no .bat required)
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");

const titlePath = path.join(process.cwd(), "title.txt");
if (!fs.existsSync(titlePath)) {
  console.error("deploy: missing title.txt");
  process.exit(1);
}

const luaName = fs.readFileSync(titlePath, "utf8").trim();
const sourcePath = path.join(process.cwd(), luaName);
if (!fs.existsSync(sourcePath)) {
  console.error(`deploy: missing bundle output ${luaName} — run bundle first`);
  process.exit(1);
}

const destDir = path.join(os.homedir(), "AppData", "Local", "lua");
const destPath = path.join(destDir, luaName);

fs.mkdirSync(destDir, { recursive: true });
fs.copyFileSync(sourcePath, destPath);
console.log(`deploy: ${luaName} -> ${destPath}`);
