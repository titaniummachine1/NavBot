/// <reference types="node" />
import { Expression } from 'moonsharp-luaparse';
import { Module } from './module';
import { Identifiers, LuaVersion } from '../common/options';
import { RecursiveMutable, RecursivePartial, RecursiveReadonly } from '../common/utility';
export type ExpressionHandler = (module: Module, expression: Expression) => string | string[] | null | undefined | void;
export type Process = (module: Module, options: RealizedOptions) => string;
export type RealizedOptions = RecursiveReadonly<{
    expressionHandler?: ExpressionHandler;
    force: boolean;
    identifiers: Identifiers;
    isolate: boolean;
    luaVersion: LuaVersion;
    metadata: boolean;
    paths: readonly string[];
    postprocess?: Process;
    preprocess?: Process;
    rootModuleName: string;
    ignoredModuleNames: readonly string[];
    resolveModule: undefined | ((name: string, packagePaths: readonly string[]) => string | null);
    sourceEncoding: BufferEncoding;
}>;
export type Options = RecursiveMutable<RecursivePartial<RealizedOptions>>;
export declare const defaultOptions: RealizedOptions;
//# sourceMappingURL=options.d.ts.map