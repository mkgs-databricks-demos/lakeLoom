# Hi Genie — offline project create (one contract question) + heads-up on an iOS-only finalize fix

**From:** Isaac (iOS)
**Date:** 2026-06-23
**Re:** Two issues from the latest onsite field session; one needs a server contract confirmation, the other is iOS-only (FYI)
**Branch:** `mg-ios-offline-multisession-project-create` (off #82 tip, continuing the offline stack)

## The field session

Onsite with a customer, the iPhone was **fully blocked from the App all day** — the **workspace IP allow-list rejected the device's IP**, so every call failed (not airplane mode; a hard network boundary). Two things broke. One is purely my side (I'll fix it in iOS, described last so you have context). The other needs **one confirmation from you** before I can build it safely.

---

## The ask — offline project create needs Option-A semantics on `POST /api/v1/projects`

I'm wiring **offline project creation**: the FDE needs to spin up a new project on a whim mid-meeting even with zero connectivity, and have it reconcile to the App later (on reconnect or a fresh pairing). My plan mirrors the offline **capture** create we already shipped:

1. iOS mints a local `UUIDv7` as the project id, shows the project in the picker immediately, and lets the user start capturing against it **offline**.
2. The `createProject` op sits in the `OperationQueue` and drains when connectivity returns.
3. Capture sessions created during the meeting are enqueued with `project_id = <local project id>` (FIFO: the project create drains *before* the captures that depend on it).

**For this to be correct, the local project id must be the authoritative server id.** Otherwise every offline capture's `project_id` FK points at an id the server never adopts, and the captures orphan.

So my one question: **does `POST /api/v1/projects` honor `client_generated_id` as Option A — i.e. on first create the new project row's `id` *is* the `client_generated_id` — exactly like captures in migration 018?**

- We already send `client_generated_id` on the create payload, and your earlier contract said it's idempotent on `(workspace_id / created_by_user_id, client_generated_id)`, returning the existing project on re-submit. What I need to confirm is the stronger **row-id == client_generated_id** guarantee (Option A), not just idempotency.
- If it's **already Option A** → I'm unblocked, nothing for you to do but confirm.
- If it's **idempotency-only** (server still assigns its own `id`) → please consider the same migration 018 treatment for projects (use `client_generated_id` as the PK when supplied, partial unique index, 201-first/200-on-resubmit, field stays optional/back-compat). That's the cleanest fix and matches the capture precedent. The alternative — iOS rewriting the local project id across the queued capture ops + uploads after the create lands — is fragile and I'd rather not.

**Two smaller confirmations while we're here:**
- **Drain ordering:** the natural FIFO order (create project → create captures → uploads) should mean a capture create can briefly 404 if it races ahead of its project's create. Your earlier "PATCH against unknown id → 404, iOS retries" answer covered captures-before-create; I'm relying on the **same** behavior for **captures-before-their-project**: a `POST /api/projects/:project_id/captures` against a not-yet-created project returns a retryable error (404/`NOT_FOUND`), **not** a permanent 4xx. Confirm that's what happens.
- My executor already classifies capture-create `notFound` as **transient/revivable** (from the #82 work, precisely because "the project's own create may still be draining"). So as long as the server returns a retryable status for the project-not-there-yet window, the existing softening handles it. Just confirming the assumption holds end-to-end.

No deploy blocker on your side beyond the Option-A confirmation — if it's already Option A, drop a one-line `hey_isaac/` note and I'll build against it.

---

## FYI — iOS-only finalize wedge (no server change needed)

For completeness, the other field failure: after stopping a >1hr offline session, I couldn't start a second one ("a capture is already in progress") and couldn't continue the first. Root cause is entirely on my side — my live capture state machine keeps a session in a `finalizing` state until its uploads drain, and offline they never do, so it blocks new recordings. **No server contract involved**; I'm fixing it by moving draining sessions off the blocking path so the mic is free immediately after stop. Flagging only so you're aware the iOS offline stack is getting one more change before the stack is device-verified and merged. Server-side you'll just see the same create/PATCH/upload ops drain whenever the device reconnects — possibly for **two or more sessions at once** after a long offline window. Nothing new on the wire.

— Isaac
