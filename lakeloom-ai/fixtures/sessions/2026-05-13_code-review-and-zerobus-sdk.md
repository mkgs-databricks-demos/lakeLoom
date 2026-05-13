# 2026-05-13 Code Review, Bug Fixes & ZeroBus SDK Patch Infrastructure

## Problems

1. **npm install timeout** — `package-lock.json` referenced `npm-proxy.dev.databricks.com` (internal Databricks employee proxy, unreachable from Apps container)
2. **TypeScript build failure** — `appkit.destroy()`, `appkit.close()`, `appkit.lakebase.close()` don't exist in AppKit API
3. **Client build failure** — `recharts` is a peer dep of `@databricks/appkit-ui` but missing from `package.json`
4. **ZeroBus SDK phantom peer dep** — declares `apache-arrow@^56.0.0` which doesn't exist on npm (latest is ~21.x)
5. **npm deprecation warnings** — `glob@10.5.0` and `node-domexception@1.0.0` from SDK transitive deps
6. **ZeroBus SDK missing NAPI-RS shim** — published tarball lacks `index.js` and `index.d.ts` (the JS entry point that loads the correct `.node` binary per platform)
7. **App initialization crash** — `files()` plugin requires `DATABRICKS_VOLUME_FILES` env var, but lakeLoom binds 3 domain-specific volumes instead

## Root Causes & Fixes

| # | Error | Root Cause | Fix |
|---|-------|-----------|-----|
| 1 | ETIMEDOUT to npm-proxy.dev.databricks.com | Lockfile generated on employee laptop with npm proxy configured | Replaced 4 proxy URLs with `registry.npmjs.org` in `package-lock.json` |
| 2 | TS2554/TS2339 in shutdown handler | Incorrect AppKit API usage — no destroy/close methods | Changed to `appkit.lakebase.pool.end()` (pg.Pool API) |
| 3 | Rolldown failed to resolve 'recharts' | Peer dep not auto-installed | Added `recharts@2.15.3` to dependencies |
| 4 | ETARGET apache-arrow@^56.0.0 | SDK has wrong semver in peerDependencies | Added `"apache-arrow": "^21.1.0"` to `overrides` in package.json |
| 5 | npm WARN deprecated glob/node-domexception | Stale transitive deps from SDK | Added `"glob": ">=11.0.0"` to `overrides` (node-domexception has no fix — only 1.0.0 exists) |
| 6 | ERR_MODULE_NOT_FOUND at runtime | NAPI-RS JS shim missing from npm tarball | Vendored `index.js` + `index.d.ts` in `patches/`, postinstall script copies into `node_modules/` |
| 7 | ConfigurationError: Missing required resources: volume:Files | `files()` plugin hardcodes `DATABRICKS_VOLUME_FILES` | Removed `files()` from plugin list — lakeLoom uses custom upload routes per volume |

## Additional Items Added

| Item | Description |
|------|-------------|
| Graceful shutdown | SIGTERM/SIGINT handlers close Lakebase PG pool before container kill |
| Health check | `GET /healthz` → 200 + `{status, timestamp}` for liveness probe |
| ErrorBoundary scope | `RouteErrorFallback` using `useRouteError()` on root route (React Router v7) |
| Route-level code splitting | `React.lazy()` + `Suspense` for Analytics, Lakebase, Files pages |
| ES2022 server target | Enables native `Array.at()`, `Object.hasOwn()`, `structuredClone`, error `.cause` |
| Tailwind AppKit-UI paths | Added `node_modules/@databricks/appkit-ui/**/*.{js,mjs}` to content config |
| .env.example cleanup | Replaced `DATABRICKS_VOLUME_FILES`/`FLASK_RUN_HOST` with actual 3 volume vars |
| Smoke test cleanup | Removed dead `genie` plugin entry from PLUGIN_PAGES |

## Decisions

- **No generic `files()` plugin** — lakeLoom has 3 purpose-specific volumes (session-audio, screenshots, documents) that will use custom upload routes, not a generic file browser
- **Patch workflow over fork** — vendoring the NAPI-RS shim is safer than forking the SDK; postinstall is a no-op if upstream fixes the tarball
- **`legacy-peer-deps=true` retained** — belt-and-suspenders alongside the `apache-arrow` override in case other transitive peer conflicts arise
- **glob override to >=11** — accepted minor risk of breaking SDK internals (our patch script bypasses native file discovery anyway); confirmed zero deprecation warnings in deploy logs
- **node-domexception accepted** — no non-deprecated version exists on npm; cosmetic only
- **Items deferred:** legacy-peer-deps doc (upstream fix needed), sample todo routes (replaced when building real schema), robots.txt/CSP (behind auth sidecar), boilerplate homepage (replaced with domain UI)

## Verification (OTel Logs)

```
[patch:zerobus-sdk] OK   index.js
[patch:zerobus-sdk] OK   index.d.ts
[patch:zerobus-sdk] Patched 2/2 files.
```

- Zero `ConfigurationError` after removing `files()` plugin
- Zero deprecation warnings after `glob` override
- Zero runtime import errors for ZeroBus SDK
- App startup: `Lakebase pool initialized` → `Server running on http://0.0.0.0:8000`
- Analytics responding: `POST /query/mocked_sales → 200`

## Files Modified

| File | Change |
|------|--------|
| `package-lock.json` | 4 npm-proxy URLs → registry.npmjs.org |
| `package.json` | +recharts dep, +overrides (apache-arrow, glob), +patch:zerobus-sdk script, postinstall chain |
| `.npmrc` | Updated documentation explaining override + legacy-peer-deps relationship |
| `.env.example` | 3 volume vars, removed Flask/generic references |
| `server/server.ts` | Removed `files()` plugin, graceful shutdown + healthz |
| `client/src/App.tsx` | ErrorBoundary scope + code splitting |
| `tsconfig.server.json` | ES2022 target |
| `client/tailwind.config.ts` | AppKit-UI content path |
| `tests/smoke.spec.ts` | Removed dead genie plugin entry |
| `scripts/patch-zerobus-sdk.mjs` | **NEW** — postinstall copies NAPI-RS shim into node_modules |
| `patches/zerobus-ingest-sdk/index.js` | **NEW** — vendored NAPI-RS platform-detection shim |
| `patches/zerobus-ingest-sdk/index.d.ts` | **NEW** — vendored TypeScript types (ZerobusSdk, ZerobusStream, etc.) |

## Known Remaining Issues

1. **Lakebase schema permission** — `Database setup failed: permission denied for schema app` (sample todo routes reference non-existent schema; will be replaced by `paired_sessions` schema)
2. **ZeroBus SDK upstream** — tarball still missing shim, phantom peer dep, 404 platform packages on some versions (all worked around by patch infra + overrides)
3. **Vite chunk size warning** — client bundle >500 KB after code splitting (recharts is heavy; could dynamic-import individual chart components)
