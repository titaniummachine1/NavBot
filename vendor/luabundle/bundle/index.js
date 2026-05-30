"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.bundle = exports.bundleString = void 0;
const fs_1 = require("fs");
const path_1 = require("path");
const options_1 = require("./options");
const process_1 = require("./process");
const metadata_1 = require("../metadata");
function mergeOptions(options) {
    return Object.assign(Object.assign(Object.assign({}, options_1.defaultOptions), options), { identifiers: Object.assign(Object.assign({}, options_1.defaultOptions.identifiers), options.identifiers) });
}
function bundleModule(module, options) {
    const postprocessedContent = options.postprocess ? options.postprocess(module, options) : module.content;
    const identifiers = options.identifiers;
    return `${identifiers.register}("${module.name}", function(require, _LOADED, ${identifiers.register}, ${identifiers.modules})\n${postprocessedContent}\nend)\n`;
}
function bundleString(lua, options = {}) {
    const realizedOptions = mergeOptions(options);
    const processedModules = {};
    (0, process_1.processModule)({
        name: realizedOptions.rootModuleName,
        content: lua,
    }, realizedOptions, processedModules);
    if (Object.keys(processedModules).length === 1 && !realizedOptions.force) {
        return lua;
    }
    const identifiers = realizedOptions.identifiers;
    const runtime = (0, fs_1.readFileSync)((0, path_1.resolve)(__dirname, './runtime.lua'), 'utf8');
    let bundle = '';
    if (realizedOptions.metadata) {
        bundle += (0, metadata_1.generateMetadata)(realizedOptions);
    }
    bundle += `local ${identifiers.require}, ${identifiers.loaded}, ${identifiers.register}, ${identifiers.modules} = ${runtime}`;
    bundle += realizedOptions.isolate ? '(nil)\n' : '(require)\n';
    for (const [name, processedModule] of Object.entries(processedModules)) {
        bundle += bundleModule({
            name,
            content: processedModule.content
        }, realizedOptions);
    }
    bundle += 'return ' + identifiers.require + '("' + realizedOptions.rootModuleName + '")';
    return bundle;
}
exports.bundleString = bundleString;
function bundle(inputFilePath, options = {}) {
    const realizedOptions = mergeOptions(options);
    const lua = (0, fs_1.readFileSync)(inputFilePath, realizedOptions.sourceEncoding);
    return bundleString(lua, options);
}
exports.bundle = bundle;
//# sourceMappingURL=index.js.map