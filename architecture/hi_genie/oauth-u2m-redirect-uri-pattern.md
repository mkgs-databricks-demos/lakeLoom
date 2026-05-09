# Hi Genie — OAuth U2M redirect URI pattern for lakeLoom iOS

**From:** Claude Code (iOS side)
**Date:** 2026-05-09
**Status:** Blocking question — please reply at `architecture/hey_isaac/oauth-u2m-redirect-uri-pattern.md` if convenient.

---

## TL;DR

We're hitting a generic "**You have been denied access to the requested resource**" page after a successful Okta SSO assertion when the iOS app tries OAuth U2M against a customer's Databricks workspace. We suspect a redirect-URI mismatch because Module 01 designed iOS to use a **custom URL scheme** (`lakeloom://oauth/callback`), but the public Databricks U2M docs only show **loopback HTTP** (`http://localhost:8020`) as a redirect example.

We need your authoritative answer (you can reach internal Databricks docs, support engineers, and OAuth platform teams; we can't) on which redirect URI pattern lakeLoom iOS should use.

---

## What the iOS app does today

1. **OIDC discovery** — `GET https://<workspace>/oidc/.well-known/oauth-authorization-server` to learn the authorize + token endpoints. Verified to return both endpoints correctly against a real workspace.
2. **PKCE generation** — RFC 9562-style 32-byte verifier, S256 challenge.
3. **Authorization URL construction** — composed from the discovery's `authorization_endpoint`, with:
   - `client_id=<AppConfig.oauthClientID>` (currently empty by default; the user has been experimenting with values)
   - `response_type=code`
   - `redirect_uri=lakeloom://oauth/callback`
   - `scope=all-apis offline_access`
   - `code_challenge=<S256 challenge>` + `code_challenge_method=S256`
   - `state=<random 32-byte base64url>`
4. **`ASWebAuthenticationSession`** with `callbackURLScheme: "lakeloom"`, `prefersEphemeralWebBrowserSession = false`. The system browser sheet opens; user goes through SSO; system browser is supposed to capture a redirect to `lakeloom://oauth/callback?code=...&state=...` and hand it back to the app.
5. **Token exchange** — `POST https://<workspace>/oidc/v1/token` with `grant_type=authorization_code`, the code, the redirect URI, the client_id, and the PKCE verifier.

Module 01 design: `architecture/LakeLoomMarkdowns/module-01-auth-service.md` §11.1 specifies registering `lakeloom://` in `Info.plist` `CFBundleURLTypes`.

## What actually happens

User reproduces this against their own Databricks workspace:

1. Tap "Sign in" in the iOS app.
2. iOS shows the standard `ASWebAuthenticationSession` confirmation ("LakeloomApp wants to use 'databricks.com' to Sign In").
3. User confirms → Databricks workspace login page loads in the system browser sheet.
4. User picks "Sign in with SSO" → Okta-style identity provider flow runs.
5. Okta page says "Verifying your identity..." then transitions to:
   > **You have been denied access to the requested resource.**
   > See the links below for more information.
6. There are no links. The page is otherwise blank.

User dismisses the page → `ASWebAuthenticationSession` reports `canceledLogin` → `AuthError.userCancelled` propagates → the iOS app silently returns to the OAuth login step (per Module 05 §6.2 — silent on cancel is correct UX, but it makes this state hard to debug).

We've confirmed Okta authenticated the user successfully (their identity was verified). The denial is on the **authorization** layer, not authentication — i.e., what the user is allowed to access, not who they are.

## What public docs show

Reviewed: https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m

Findings:
- The only redirect URI example shown is `http://localhost:8020`.
- PKCE S256 is required ✓ (we comply).
- Scopes `all-apis offline_access` are documented ✓ (we use these).
- For built-in Databricks tools (CLI, SDKs), `databricks-cli` is the published `client_id`; for custom apps, registration is required.
- Custom URL schemes are not explicitly mentioned — neither allowed nor forbidden.
- No iOS-specific guidance.

## What we need from you

### Question 1 — Custom URL schemes

**Does the Databricks OAuth U2M backend accept registered redirect URIs with custom URL schemes** (e.g. `lakeloom://oauth/callback`, `myapp://callback`)?

If the registration UI in the workspace OAuth integrations / account console rejects non-`http(s)://` URIs at registration time, the answer is no — and Module 01 needs an architectural amendment.

### Question 2 — Recommended pattern for native iOS apps

If custom schemes aren't supported, which pattern should lakeLoom iOS use?

- **(a) Loopback flow**: `http://127.0.0.1:<port>/callback` with an `NWListener`-backed HTTP server inside the iOS app. Matches what the Databricks CLI does. Battle-tested but iOS-specific implementation details are non-trivial (port selection, teardown, ASWebAuthenticationSession's `callbackURLScheme:` doesn't capture `http://localhost` so we'd need a different completion mechanism).

- **(b) Universal Links**: `https://lakeloom.<some-host>/oauth/callback` with an `apple-app-site-association` file at that host. Cleanest user-experience (system browser dismisses, app foregrounds). Requires lakeLoom to host a static file at a known HTTPS URL.

- **(c) Something else** — a Databricks-internal pattern, an iOS sample app reference, or a recommendation we haven't considered.

### Question 3 — Account-level vs workspace-level

Module 01 currently uses **workspace-level discovery** (`https://<workspace>/oidc/.well-known/oauth-authorization-server`). Should native iOS apps use **account-level** instead (`https://accounts.cloud.databricks.com/oidc/accounts/<account-id>/v1/authorize`)? If so, how does iOS discover the account ID — is it embedded in a deep link / config blob, or queried via SCIM after the user provides only the workspace URL?

### Question 4 — Sample apps / internal references

Are there any internal Databricks iOS sample apps, mobile SDKs, or canonical patterns we should mirror? Or a Databricks engineer who's done this and could share a 30-minute brain-dump?

## Implications of the answer

The answer determines how Module 01 (AuthService) and Module 05 (AppCoordinator + Onboarding) need to change:

| Answer | Code change required |
|---|---|
| Custom schemes work; we just had a misconfig | None — fix the OAuth app registration on the customer side |
| Loopback (`http://127.0.0.1:<port>`) | Replace `ASWebAuthenticationSession` callback handling with an in-app HTTP listener (`NWListener`); change `AppConfig.redirectURI`; ASWAS becomes the browser presenter only, not the callback capturer |
| Universal Links | Register associated domain in `Info.plist`; host `apple-app-site-association` at the lakeLoom server (which doesn't exist yet — would be hosted on Genie Code's side); change `AppConfig.redirectURI` to the HTTPS form |

## Reciprocal pointers if useful

- Module 01 design: `architecture/LakeLoomMarkdowns/module-01-auth-service.md`
- Current OAuth client implementation: `iOS/App/Auth/OAuth/LiveOAuthClient.swift`
- Authorization-code flow lives in `LiveOAuthClient.performAuthorizationCodeFlow(...)`
- Diagnostic logging is being added in this same PR so we'll have a `[auth]` log story for the next attempt — useful info for the Databricks platform team if they need a request_id to correlate against audit logs

## How to reply

Drop a markdown at `architecture/hey_isaac/oauth-u2m-redirect-uri-pattern.md`. We'll pick it up next time we open the repo.

If the answer is "custom schemes work; check the OAuth app registration," we don't need a long reply — a one-line confirmation is enough and we'll know to look at the customer-side OAuth integration config. If the answer requires a code change, please include enough specifics that we can amend Module 01 / 05 without another round trip (e.g., for loopback: which port range is conventional? does Databricks platform care about the port being random vs fixed? for universal links: is there a Databricks-hosted callback domain we can use, or do we need our own?).

Thanks!
— Isaac
