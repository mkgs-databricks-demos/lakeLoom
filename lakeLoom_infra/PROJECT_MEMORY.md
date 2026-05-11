# lakeLoom Project Memory

## Purpose

Project-local durable context for `lakeLoom_infra` when global instructions are unavailable from this editing scope.

## Collaboration Conventions

### Isaac collaboration folders

* `hi_genie/` is read-only context from Isaac.
* Always read `hi_genie/` for relevant project context before substantive work.
* Never write to `hi_genie/`, any subfolder inside it, or any file within it.
* Reply to Isaac, share progress, or record decisions in a sibling `hey_isaac/` folder at the same project root if present.
* Genie is the source of truth for Databricks-related decisions; Isaac is useful for non-Databricks domains such as Xcode and Apple-platform development.

## Project Structure

* Major roots reviewed: `iOS/`, `architecture/LakeLoomMarkdowns/`, and `lakeLoom_infra/`.
* `architecture/hi_genie/` contains read-only design and implementation context from Isaac.
* Recent merged app-side changes center on QR-pair onboarding, session management, auth flows, and coordinator-based navigation.

## Current Infra Status

* Bundle project name: `lakeLoom_infra`.
* Bundle root: `/Workspace/Users/matthew.giglia@databricks.com/lakeLoom/lakeLoom_infra`.
* `bundle validate --strict --target dev` passed previously.
* Bundle summary showed resources tracked but not yet deployed at the time of review.
* `resources/uc_setup.job.yml` was still empty and is the primary blocker to operational deployment.

## Recent Repository State

* Feature branch `mg-start-infra` was merged with `main` cleanly during review.
* Notable newer project context after sync was concentrated in `iOS/` and `architecture/hi_genie/`.
* Key app themes observed: QR pairing auth, onboarding expansion, `AppCoordinator`, `QRScannerView`, `LoopbackCallbackListener`, Secure Enclave signing, and related tests.

## Recommended Next Steps

* Draft `resources/uc_setup.job.yml` to complete bootstrap and unblock deployment.
* Keep app/infra sequencing aligned with QR-pair onboarding requirements.
* When possible, copy any still-relevant items here into the global `.assistant_instructions.md` file as well.
