// Simple file watcher using Node.js built-in modules
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');

console.log('🔄 Starting Simple Auto-Bundle Watcher for NavBot...');

// Bundle function
function bundle() {
    return new Promise((resolve, reject) => {
        console.log('📦 Bundling NavBot...');
        exec('node bundle.js', (error, stdout, stderr) => {
            if (error) {
                console.error('❌ Bundle failed:', error.message);
                reject(error);
                return;
            }
            console.log('✅ Bundle successful');
            
            // Auto-deploy
            console.log('🚀 Auto-deploying...');
            exec('BundleAndDeploy.bat', (deployError, deployStdout, deployStderr) => {
                if (deployError) {
                    console.error('❌ Deploy failed:', deployError.message);
                } else {
                    console.log('✅ Deploy successful');
                }
            });
            
            resolve(stdout);
        });
    });
}

// Simple file watcher using fs.watch
const watchDir = 'NavBot';
console.log(`👀 Watching ${watchDir} for changes...`);

function watchDirectory(dir) {
    if (!fs.existsSync(dir)) {
        console.error(`❌ Directory ${dir} does not exist`);
        return;
    }

    fs.watch(dir, { recursive: true }, (eventType, filename) => {
        if (filename && filename.endsWith('.lua')) {
            console.log(`📝 File changed: ${path.join(dir, filename)}`);
            
            // Debounce rapid changes
            setTimeout(() => {
                bundle().catch(console.error);
            }, 500);
        }
    });
}

watchDirectory(watchDir);

// Initial bundle
bundle().catch(console.error);

console.log('🎯 Press Ctrl+C to stop');

// Handle Ctrl+C
process.on('SIGINT', () => {
    console.log('\n👋 Stopping watcher...');
    process.exit(0);
});
