// Hot reload script for LMAOBox integration
const fs = require("node:fs");
const path = require("node:path");

console.log("🔥 Starting Hot Reload System for NavBot...");

// Get LMAOBox Lua directory
const luaDir = String.raw`${process.env.LOCALAPPDATA}\Lua`;

// Hot reload function
function hotReload() {
  const sourceFile = "NavBot.lua";
  const targetFile = path.join(luaDir, "NavBot.lua");

  if (fs.existsSync(sourceFile)) {
    try {
      fs.copyFileSync(sourceFile, targetFile);
      console.log("🔥 Hot reloaded NavBot.lua to LMAOBox");
    } catch (error) {
      console.error("❌ Hot reload failed:", error.message);
    }
  }
}

// Watch for bundle changes
const bundleWatcher = fs.watchFile("NavBot.lua", (curr, prev) => {
  if (curr.mtime !== prev.mtime) {
    console.log("📦 Bundle updated, hot reloading...");
    hotReload();
  }
});

// Manual hot reload command
if (process.argv.includes("--reload")) {
  hotReload();
}

// Watch mode
if (!process.argv.includes("--once")) {
  console.log("👀 Watching NavBot.lua for changes...");
  console.log("🎯 Press Ctrl+C to stop");
}

console.log("✅ Hot reload system ready");
