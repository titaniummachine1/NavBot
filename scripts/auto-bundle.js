// Auto-bundle script with file watching
const fs = require('node:fs');
const path = require('node:path');
const { exec } = require('node:child_process');
const chokidar = require('chokidar');

console.log('🔄 Starting Auto-Bundle Watcher for NavBot...');

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

            // Auto-deploy if enabled
            if (process.env.AUTO_DEPLOY === 'true') {
                console.log('🚀 Auto-deploying...');
                exec('BundleAndDeploy.bat', (deployError) => {
                    if (deployError) {
                        console.error('❌ Deploy failed:', deployError.message);
                    } else {
                        console.log('✅ Deploy successful');
                    }
                });
            }

            resolve(stdout);
        });
    });
}

// File watcher
const watcher = chokidar.watch('NavBot/**/*.lua', {
    ignored: /node_modules/,
    persistent: true,
    ignoreInitial: true
});

watcher.on('change', async (path) => {
    console.log(`📝 File changed: ${path}`);
    try {
        await bundle();
    } catch (error) {
        console.error('Auto-bundle failed:', error);
    }
});

watcher.on('add', async (path) => {
    console.log(`➕ File added: ${path}`);
    try {
        await bundle();
    } catch (error) {
        console.error('Auto-bundle failed:', error);
    }
});

console.log('👀 Watching for file changes...');
console.log('🎯 Press Ctrl+C to stop');

// Initial bundle
try {
    await bundle();
} catch (error) {
    console.error('Initial bundle failed:', error);
}
