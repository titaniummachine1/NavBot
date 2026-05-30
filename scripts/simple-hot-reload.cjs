// Simple hot reload script using Node.js built-in modules
const fs = require('fs');
const path = require('path');

console.log('🔥 Starting Simple Hot Reload System for NavBot...');

// Get LMAOBox Lua directory
const luaDir = process.env.LOCALAPPDATA + '\\Lua';

// Hot reload function
function hotReload() {
    const sourceFile = 'NavBot.lua';
    const targetFile = path.join(luaDir, 'NavBot.lua');
    
    if (fs.existsSync(sourceFile)) {
        try {
            fs.copyFileSync(sourceFile, targetFile);
            console.log('🔥 Hot reloaded NavBot.lua to LMAOBox');
            
            // Simple notification
            const timestamp = new Date().toLocaleTimeString();
            console.log(`✅ Hot reloaded at ${timestamp}`);
        } catch (error) {
            console.error('❌ Hot reload failed:', error.message);
        }
    } else {
        console.log('⚠️  NavBot.lua not found, waiting for bundle...');
    }
}

// Watch for bundle changes
console.log('👀 Watching NavBot.lua for changes...');

if (fs.existsSync('NavBot.lua')) {
    const watcher = fs.watchFile('NavBot.lua', (curr, prev) => {
        if (curr.mtime !== prev.mtime) {
            console.log('📦 Bundle updated, hot reloading...');
            hotReload();
        }
    });
} else {
    console.log('⚠️  NavBot.lua not found, will start watching when it appears');
    
    // Check periodically for file creation
    const checkInterval = setInterval(() => {
        if (fs.existsSync('NavBot.lua')) {
            console.log('✅ NavBot.lua found, starting hot reload watcher');
            clearInterval(checkInterval);
            
            const watcher = fs.watchFile('NavBot.lua', (curr, prev) => {
                if (curr.mtime !== prev.mtime) {
                    console.log('📦 Bundle updated, hot reloading...');
                    hotReload();
                }
            });
        }
    }, 1000);
}

// Manual hot reload command
if (process.argv.includes('--reload')) {
    hotReload();
}

console.log('✅ Hot reload system ready');
console.log('🎯 Press Ctrl+C to stop');

// Handle Ctrl+C
process.on('SIGINT', () => {
    console.log('\n👋 Stopping hot reload...');
    process.exit(0);
});
