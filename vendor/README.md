# Vendored bundle tools

`luabundle` and `moonsharp-luaparse` are committed here so **no `npm install` is required** for local builds or GitHub Actions.

To refresh after upgrading the bundler:

```bash
npm install luabundle@1.7.0 --no-save
xcopy /E /I /Y node_modules\luabundle vendor\luabundle
xcopy /E /I /Y node_modules\moonsharp-luaparse vendor\luabundle\node_modules\moonsharp-luaparse
```
