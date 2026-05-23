# Session Index

* [2026-05-23] Device Identity Contract Implementation — `2026-05-23_device-identity-contract.md`
* [2026-05-21] ZeroBus Ingest Root Cause Fix & Full Validation — `2026-05-21_zerobus-ingest-root-cause-and-validation.md`
* [2026-05-21] ZeroBus Scale-to-Zero Stream Pool Implementation — `2026-05-21_zerobus-scale-to-zero-implementation.md`
* [2026-05-21] AppKit Files Plugin: Zero-Byte Upload Fix — `2026-05-21_appkit-files-plugin-zero-byte-fix.md`
* [2026-05-20] Audio Upload E2E Fix — `2026-05-20_audio-upload-e2e-fix.md`
* [2026-05-16] Upload Handler P0 Hardening — `2026-05-16_upload-handler-p0-hardening.md`
* [2026-05-16] Phase 2 Device UX + User Identity + Multipart Auth Fix — `2026-05-16_phase2-device-ux-identity-multipart-fix.md`

| Date | Summary | File |
|------|---------|------|
| 2026-05-23 | Full device_id contract: migration 008, route handlers, test notebooks, column mapping fix, E2E validated | [device-identity-contract](./2026-05-23_device-identity-contract.md) |
| 2026-05-21 | Root cause: object vs string passing to ZeroBus SDK; fix validated with 100-event load test, auto-scale to 3 streams, CI/CD teardown | [zerobus-ingest-root-cause-and-validation](./2026-05-21_zerobus-ingest-root-cause-and-validation.md) |
| 2026-05-21 | Scale-to-zero ZeroBus pool rewrite: class-based singleton, auto-scaling, Lakebase persistence, health endpoints, validation notebook | [zerobus-scale-to-zero-implementation](./2026-05-21_zerobus-scale-to-zero-implementation.md) |
| 2026-05-21 | Replaced broken SDK upload with AppKit 0.36.0 files() plugin; SP mode + allowAll policy; bytes verified on volume | [appkit-files-plugin-zero-byte-fix](./2026-05-21_appkit-files-plugin-zero-byte-fix.md) |
| 2026-05-20 | Fixed iosAuth middleware invocation + SDK 0.17 object-signature mismatch; first successful audio upload E2E | [audio-upload-e2e-fix](./2026-05-20_audio-upload-e2e-fix.md) |
| 2026-05-15 | Full project audit, Isaac messages reviewed, PROJECT_MEMORY + UI plan updated to reflect current state | [project-review-and-memory-update](./2026-05-15_project-review-and-memory-update.md) |
| 2026-05-14 | iOS auth 3-bug fix (token hash, empty body, Express req.body), E2E pairing test, IP access list docs | [ios-auth-fixes-e2e-pairing](./2026-05-14_ios-auth-fixes-e2e-pairing.md) |
| 2026-05-14 | Phase 1 project management, QR host fix, cursor pagination, dualAuth | [phase1-projects-and-qr-host-fix](./2026-05-14_phase1-projects-and-qr-host-fix.md) |
| 2026-05-14 | Photos endpoint, App SPN volume grants, orphan-byte sweeper, Isaac ack | [photos-grants-sweeper](./2026-05-14_photos-grants-sweeper.md) |
| 2026-05-14 | Upload traceability: tables, routes, multipart, CI/CD validation job, deploy.sh Step 7 | [upload-traceability-implementation](./2026-05-14_upload-traceability-implementation.md) |
| 2026-05-13 | Job split (git_source fix), serverless env version, pairing API test notebook, endpoints validated | [job-split-and-api-test](./2026-05-13_job-split-and-api-test.md) |
| 2026-05-13 | QR-pair auth implementation, bundle restructure, configure_app_spn job | [qr-pair-auth-and-bundle-restructure](./2026-05-13_qr-pair-auth-and-bundle-restructure.md) |
| 2026-05-13 | Code review (15 items), ZeroBus SDK patch infra, npm proxy fix, volume error fix | [code-review-and-zerobus-sdk](./2026-05-13_code-review-and-zerobus-sdk.md) |
| 2026-05-13 | deploy.sh cascading failures — JSON parse, f-string, app status, path_safe | [deploy-sh-bugfixes](./2026-05-13_deploy-sh-bugfixes.md) |
