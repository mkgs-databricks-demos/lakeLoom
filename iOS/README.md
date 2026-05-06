# lakeLoom iOS

Native iOS client for the lakeLoom rapid-MVP capture tool. Captures requirements-gathering sessions on iPhone, posts them to the lakeLoom Databricks App over HTTPS, and uploads session audio to a Unity Catalog Volume for server-side re-transcription.

> Internal Databricks tool. Not for App Store distribution in v1.

---

## Prerequisites

- **macOS** 15 or later
- **Xcode** 26.0+ (uses iOS 26 `SpeechAnalyzer`; minimum deployment target is iOS 26)
- **Homebrew** — for build tooling (`xcodegen`, `swiftlint`, `swift-format`, `xcbeautify`)
- A Databricks workspace + an OAuth U2M client_id for the lakeLoom app (configured per Module 01)

## First-time setup

```sh
make setup
```

This runs `brew bundle` and `xcodegen generate`. Open the generated project:

```sh
open LakeloomApp.xcodeproj
```

## Common tasks

| Command | What it does |
|---|---|
| `make project` | Regenerate `LakeloomApp.xcodeproj` from `project.yml` after a config change |
| `make build` | Debug build on the default simulator |
| `make test` | Run unit + UI tests with code coverage |
| `make lint` | Run SwiftLint and swift-format checks |
| `make clean` | Remove the generated project and DerivedData |
| `make help` | Show all available targets |

Override the simulator destination:

```sh
make test DEST='platform=iOS Simulator,name=iPhone 17 Pro'
```

## Project structure

```
iOS/
├── project.yml                  # xcodegen spec — source of truth for the project
├── Makefile                     # common dev tasks
├── Brewfile                     # Homebrew dependencies
├── .swiftlint.yml               # lint rules
├── .swift-format                # format rules
│
├── App/                         # application source (mirrors module designs in
│   ├── LakeloomApp.swift        #  architecture/LakeLoomMarkdowns/)
│   ├── Auth/                    # Module 01
│   ├── Capture/                 # Module 02
│   ├── Ingest/                  # Module 03
│   ├── Storage/                 # Module 04
│   ├── Coordinator/             # Module 05
│   ├── Projects/                # Module 06
│   ├── Persistence/             # Module 07
│   ├── Views/                   # Module 08 (UI layer)
│   ├── Telemetry/               # Module 09
│   ├── AppSync/                 # Module 11
│   ├── Common/                  # shared utilities (UUIDv7, etc.)
│   └── Resources/               # Assets, Info.plist values, PrivacyInfo
│
├── AppTests/                    # unit tests (mirror App/ layout)
├── AppUITests/                  # XCUITest smoke tests
├── BuildScripts/                # lint.sh and other helpers
└── session_summaries/           # one markdown per dev session, dated
```

The `LakeloomApp.xcodeproj` directory is **generated** from `project.yml`. Edit the YAML, then `make project`. Both `project.yml` and the generated `.xcodeproj` are committed so cloning + opening in Xcode is one step.

## Architecture

The full design lives in `architecture/LakeLoomMarkdowns/` at the repo root:

- `ios-app-architecture.md` — overview, ZeroBus/ingest data contract, layer diagram
- `module-01-auth-service.md` through `module-11-app-sync.md` — per-module designs

A few rules worth knowing before you contribute:

- **Single network boundary.** iOS speaks HTTPS to one host: the Databricks App. No gRPC to ZeroBus, no direct Postgres to Lakebase, no SQL Statement Execution.
- **OAuth 2.0 U2M only.** Each user is a member of the Databricks workspace. Service principals are never used on iOS.
- **Swift 6 strict concurrency.** `SWIFT_STRICT_CONCURRENCY = complete` is set in `project.yml`. New code is expected to compile cleanly under it.
- **Polish + best practice as the default.** Accessibility (Dynamic Type, VoiceOver), Dark Mode, snapshot tests, and design-system tokens from day one — not retrofitted.

## Contributing

- Branch off `main` (`feature/<short-name>`). Never commit to `main` directly.
- Commit and push often, with thoughtful messages explaining the *why*.
- Write a session summary at `iOS/session_summaries/YYYY-MM-DD-HHMM-short-title.md` before opening a PR.
