"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.processModule = exports.resolveModule = void 0;
const fs_1 = require("fs");
const path_1 = require("path");
const moonsharp_luaparse_1 = require("moonsharp-luaparse");
const ast_1 = require("../ast");
const metadata_1 = require("../metadata");
const ModuleBundlingError_1 = __importDefault(require("../errors/ModuleBundlingError"));
const ModuleResolutionError_1 = __importDefault(require("../errors/ModuleResolutionError"));
function resolveModule(name, packagePaths) {
    const platformName = name.replace(/\./g, path_1.sep);
    for (const pattern of packagePaths) {
        const path = pattern.replace(/\?/g, platformName);
        if ((0, fs_1.existsSync)(path) && (0, fs_1.lstatSync)(path).isFile()) {
            return path;
        }
    }
    return null;
}
exports.resolveModule = resolveModule;
function processModule(module, options, processedModules) {
    let content = options.preprocess ? options.preprocess(module, options) : module.content;
    const resolvedModules = [];
    // Ensure we don't attempt to load modules required in nested bundles
    if (!(0, metadata_1.readMetadata)(content)) {
        let ast = (0, moonsharp_luaparse_1.parse)(content, {
            locations: true,
            luaVersion: options.luaVersion,
            ranges: true,
        });
        (0, ast_1.reverseTraverseRequires)(ast, expression => {
            var _a;
            const argument = expression.argument || expression.arguments[0];
            let required = null;
            if (argument.type == 'StringLiteral') {
                required = argument.value;
            }
            else if (options.expressionHandler) {
                required = options.expressionHandler(module, argument);
            }
            if (required) {
                const requiredModuleNames = Array.isArray(required) ? required : [required];
                for (const requiredModule of requiredModuleNames) {
                    const resolvedPath = options.resolveModule
                        ? options.resolveModule(requiredModule, options.paths)
                        : resolveModule(requiredModule, options.paths);
                    if (!resolvedPath) {
                        if (!options.ignoredModuleNames.includes(requiredModule)) {
                            const start = (_a = expression.loc) === null || _a === void 0 ? void 0 : _a.start;
                            throw new ModuleResolutionError_1.default(requiredModule, module.name, start.line, start.column);
                        }
                        else {
                            continue;
                        }
                    }
                    resolvedModules.push({
                        name: requiredModule,
                        resolvedPath,
                    });
                }
                if (typeof required === "string") {
                    const range = expression.range;
                    const baseRange = expression.base.range;
                    content = content.slice(0, baseRange[1]) + '("' + required + '")' + content.slice(range[1]);
                }
            }
        });
    }
    processedModules[module.name] = Object.assign(Object.assign({}, module), { content });
    for (const resolvedModule of resolvedModules) {
        if (processedModules[resolvedModule.name]) {
            continue;
        }
        try {
            const moduleContent = (0, fs_1.readFileSync)(resolvedModule.resolvedPath, options.sourceEncoding);
            processModule(Object.assign(Object.assign({}, resolvedModule), { content: moduleContent }), options, processedModules);
        }
        catch (e) {
            throw new ModuleBundlingError_1.default(resolvedModule.name, e);
        }
    }
}
exports.processModule = processModule;
//# sourceMappingURL=process.js.map