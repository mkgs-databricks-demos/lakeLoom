# Device Verification — finalize de-wedge + offline project create (#83)

**Build:** `mg-ios-offline-multisession-project-create` (#83 — on top of #77 + #81 + #82)
**Device:** physical iPhone, paired to `lakeloom-ai-dev`
**Goal:** verify the two field failures from the June onsite (IP-allow-list blocked → fully offline) are fixed on-device. Unit tests are green; these are the paths units can't reach (real stop→start while offline, real reconnect drain). **Run alongside** the existing 4/7/8/9 checklist — the stack merges only when all pass.

## Context — the onsite that prompted this
Offline all day (workspace IP allow-list rejected the device). Two failures:
1. Couldn't create a project on a whim offline → had to reuse an existing one. (Scenario 11.)
2. Stopped a >1hr session at lunch; afterward couldn't start a second session ("a capture is already in progress") and couldn't continue the first. (Scenario 10.)

---

## Scenario 10 — Stop a long offline session, then start another  ⭐ (the wedge)
**Setup:** Airplane mode **ON** for the whole test.
**Steps:**
1. Start **session #1**; let it run a few minutes (long enough to rotate ≥1 chunk); **Stop**.
2. Immediately confirm the UI returns to idle — **no "a capture is already in progress" error**.
3. Start **session #2**; record a couple minutes; **Stop**.
4. Turn networking back **ON**; let the outbox + uploads drain (toggle off→on once to stress reconnect).

**Expect (the fix working):**
- Step 2/3: starting session #2 **succeeds** while #1's uploads are still pending — session #1 is *demoted* to a background finalizer, not blocking the mic.
- After reconnect: **both** sessions' audio uploads land + are playable; **both** reach `completed` (one foreground, one via the background finalizer / a later launch).
- No session stuck `.active`; no `UPLOAD_CAPTURE_NOT_FOUND` loop.

**Logs to confirm:** `capture.background_finalize.start` (session #1 demoted on the second start), `capture.background_finalize.completed` (or `capture.recover.older_completed` if it lands on a later launch), `upload.attempt.ok` for every chunk of both sessions.

- [ ] **PASS** — second session starts offline; both sessions complete + playable; nothing wedged.

---

## Scenario 11 — Create a project fully offline, record into it, reconcile
**Setup:** Airplane mode **ON**. **Prereq:** `ProjectService.offlineCreateEnabled == true` — only flip this once Genie confirms Option-A (`hi_genie/2026-06-23_offline-project-create-and-multisession-finalize.md`). If still gated off, this scenario is **N/A** and offline create is expected to fail fast (online-only) — note that and skip.
**Steps:**
1. Create a **new project** ("Onsite kickoff") while offline. Confirm it appears in the picker immediately.
2. Record a short session **into that new project**; **Stop**.
3. Turn networking back **ON**; toggle off→on once.

**Expect (gate ON + Option-A):**
- The project shows locally at once and is selectable for capture offline.
- On reconnect: the `createProject` op drains first (FIFO), then the capture create, then the audio — **same project id** throughout (server adopted `client_generated_id`).
- Project visible in the Databricks app; the session + audio attached to it; nothing orphaned.

**Logs to confirm:** `project.create.queued_offline` (local mint), `project.create.queued_reconciled` (server adopted it), then the capture create + `upload.attempt.ok`. A capture create may briefly retry `notFound` until the project create lands — that's expected (transient).

- [ ] **PASS** — offline-created project + its session/audio all reconcile under one stable id.

---

## Sign-off
| Scenario | Result | Notes |
|---|---|---|
| 10 — stop long offline session → start another | ☐ | |
| 11 — create project offline → record → reconcile (gate ON) | ☐ | |

When 10 + 11 (plus the existing 4/7/8/9) pass, #83 → the whole offline stack is device-verified and clear to merge bottom-up: **#77 → #81 → #82 → #83**.

— Checklist authored by Isaac
