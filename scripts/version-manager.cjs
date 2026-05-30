// Version management script
const fs = require('node:fs');
const path = require('node:path');
const { exec } = require('node:child_process');

class VersionManager {
    packagePath = 'package.json';
    versionPath = 'VERSION';

    getCurrentVersion() {
        try {
            if (fs.existsSync(this.packagePath)) {
                const packageData = JSON.parse(fs.readFileSync(this.packagePath, 'utf8'));
                return packageData.version;
            } else if (fs.existsSync(this.versionPath)) {
                return fs.readFileSync(this.versionPath, 'utf8').trim();
            }
        } catch (error) {
            console.error('❌ Failed to read current version:', error.message);
        }
        return '1.0.0';
    }

    updateVersion(newVersion) {
        try {
            // Update package.json
            if (fs.existsSync(this.packagePath)) {
                const packageData = JSON.parse(fs.readFileSync(this.packagePath, 'utf8'));
                packageData.version = newVersion;
                fs.writeFileSync(this.packagePath, JSON.stringify(packageData, null, 2));
            }

            // Update VERSION file
            fs.writeFileSync(this.versionPath, newVersion);

            console.log(`✅ Version updated to ${newVersion}`);
            return true;
        } catch (error) {
            console.error('❌ Failed to update version:', error.message);
            return false;
        }
    }

    bumpVersion(type) {
        const current = this.getCurrentVersion();
        const parts = current.split('.').map(Number);

        let [major, minor, patch] = parts;

        switch (type) {
            case 'major':
                major++;
                minor = 0;
                patch = 0;
                break;
            case 'minor':
                minor++;
                patch = 0;
                break;
            case 'patch':
                patch++;
                break;
            default:
                console.error('❌ Invalid bump type. Use: major, minor, patch');
                return false;
        }

        const newVersion = `${major}.${minor}.${patch}`;
        return this.updateVersion(newVersion);
    }

    getVersionFromCommit(message) {
        if (/^(major|feat|breaking|BREAKING)/.test(message)) {
            return 'major';
        } else if (/^(minor|feature|feat|new)/.test(message)) {
            return 'minor';
        } else if (/^(patch|fix|bug|hotfix|update)/.test(message)) {
            return 'patch';
        }
        return null;
    }
}

// CLI interface
const vm = new VersionManager();
const command = process.argv[2];
const value = process.argv[3];

switch (command) {
    case 'get':
        console.log(vm.getCurrentVersion());
        break;
    case 'set':
        if (value) {
            vm.updateVersion(value);
        } else {
            console.error('❌ Please provide a version number');
        }
        break;
    case 'bump':
        if (value) {
            vm.bumpVersion(value);
        } else {
            console.error('❌ Please provide bump type: major, minor, patch');
        }
        break;
    case 'auto':
        // Get last commit message and auto-bump
        exec('git log -1 --pretty=%B', (error, stdout) => {
            if (error) {
                console.error('❌ Failed to get commit message:', error.message);
                return;
            }
            const bumpType = vm.getVersionFromCommit(stdout.trim());
            if (bumpType) {
                vm.bumpVersion(bumpType);
            } else {
                console.log('ℹ️  No version bump needed for this commit type');
            }
        });
        break;
    default:
        console.log('Version Manager CLI');
        console.log('Usage: node version-manager.js <command> [value]');
        console.log('Commands:');
        console.log('  get                    - Get current version');
        console.log('  set <version>          - Set specific version');
        console.log('  bump <type>            - Bump version (major|minor|patch)');
        console.log('  auto                   - Auto-bump based on commit message');
}
