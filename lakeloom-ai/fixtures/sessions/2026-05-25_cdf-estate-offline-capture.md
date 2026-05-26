# Session: CDF Estate + Offline Capture + Pipeline Design

**Date:** 2026-05-25 (evening session)
**Branch:** `mg-isaac-genie-interaction`
**Status:** Pushed to origin, ready for PR

---

## Summary

Enabled Change Data Feed (CDF) across all Lakebase sync tables, deployed + verified migrations 017–018 for capture session improvements, implemented the offline capture contract (client-generated IDs with idempotency), and documented the capture-completion AI pipeline trigger architecture.

---

## Changes

### CDF Estate (all tables now enabled)

| Table | CDF | Key signals |
|-------|-----|-------------|
| `lb_capture_sessions_history` | ✅ enabled this session | state→completed, label edits |
| `lb_paired_sessions_history` | ✅ enabled this session | device label changes, re-pair |
| `lb_projects_history` | ✅ enabled this session | name/description edits, archive |
| `lb_uploads_history` | ✅ (previously enabled) | document content edits (sha256) |
| `transcript_events_raw` | ✅ (previously enabled) | append-only ZeroBus bronze |

### Migrations Verified in OTel

| Migration | Deployed | Verified |
|-----------|----------|----------|
| 017 (capture_sessions updated_at) | 19:17:19 UTC | ✅ Applied 1 migration |
| 018 (capture_sessions client_generated_id) | 20:21:36 UTC | ✅ Applied 1 migration |

### Offline Capture Contract (Migration 018 + Handler)

* `client_generated_id UUID` column on `app.capture_sessions`
* Partial unique index: `(created_by_user_id, client_generated_id) WHERE client_generated_id IS NOT NULL`
* Option A: `client_generated_id` used directly as row's primary key `id`
* Idempotent: re-POST returns 200 with existing row, new insert returns 201
* Out-of-order PATCH → 404 (iOS retries after create lands)

### Documentation

* **Updated:** `fixtures/phase5-document-edit-cdf-pipeline.md` — appended full capture-completion pipeline trigger architecture (bronze/silver/gold SDP, latency budget, trigger conditions, edge cases)
* **Created:** `architecture/hey_isaac/2026-05-25_phase2-offline-capture-reply.md` — confirms contract, answers all 3 open questions, documents CDF bonus

---

## Commits

| Hash | Description |
|------|-------------|
| `da40804` | fix: add updated_at to capture_sessions (migration 017), reply to Isaac |
| `59be38c` | docs: capture-completion pipeline trigger design |
| `b8a42d7` | docs: reply to Isaac — offline capture contract confirmed |

---

## Key Decisions

1. **CDF on all tables** — future-proofs pipeline triggers; negligible storage cost on small tables
2. **Capture-completion as AI pipeline trigger** — `state = 'completed'` in CDF postimage is the Phase 5 entry point
3. **Latency budget ~3–7 min** — Lakebase→Sync (60s) + streaming (10s) + Whisper+LLM (2–5 min)
4. **Dedup on first completion** — filter `ended_at IS NOT NULL AND ended_at > started_at` to avoid re-processing label edits

---

## Pipeline Architecture (Phase 5 — not yet built)

```
CDF trigger (state→completed)
  → Bronze: capture_completions (streaming table)
    → Silver: capture_context (enriched with audio/docs/transcript)
      → Gold: capture_deliverables (Whisper + PRD + architecture + session plan)
```

---

## Next Steps

1. Open PR for `mg-isaac-genie-interaction` branch
2. Isaac wires iOS `OperationQueue` against the offline capture contract
3. Phase 5: scaffold SDP pipeline for capture-completion processing
4. Phase 5: Vector Search index on document content (for RAG)
