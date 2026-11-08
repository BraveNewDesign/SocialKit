# SocialKit design

SocialKit is a Swift 6 package with one library module. Each provider implements a typed adapter. The client exposes paginated post and reply reads, text and media publishing, and supported engagement through the same credential path. A client binds one adapter to a credential store and can manage multiple accounts for that provider. A store can be shared by clients. Credentials are keyed by provider, HTTPS origin, and provider user ID.

The standard HTTP transport uses an ephemeral URLSession with redirects disabled. Providers decide how to authenticate, interpret responses, and deduplicate writes. The core translates ambiguous HTTP outcomes and never automatically replays a write. Callers supply a stable UUID per intended post and retain it until the result is known.

The macOS/iOS Keychain store is for production. The in-memory store and injectable transport allow testing without network or secrets. Account details and credentials are separate in the client API. Only adapters, stores, and the consuming app’s OAuth exchange implementation handle tokens directly. Public OAuth uses an injected browser and locally generated S256 verifier. Confidential token exchanges go through the consuming app’s trusted service.

## Implementation checklist

- [x] Build and test the foundation with a mock adapter.
- [x] Implement provider authentication, publishing, retrieval, and supported engagement.
- [x] Exercise success, failure, and ambiguous writes using scripted HTTP.
- [x] Add setup examples and macOS CI.
- [x] Review token handling, concurrency, provider scope, and dependency licenses.
- [x] Document expansion requirements and gaps in live verification.

## Review and verification boundaries

- **Credentials.** Provider tokens use the data protection Keychain. OAuth registration credentials stay in memory. Bluesky connects to a caller-selected HTTPS origin and sends public AppView reads without account credentials. Transport errors omit raw bodies and URLs.
- **Concurrency.** Swift 6 checks the adapter, store, and transport boundaries. The client isolates same-account operations so a refresh or disconnect cannot interrupt an in-flight publish through the same client. Separate accounts can operate concurrently.
- **Publishing.** The provider handles duplicate detection. Bluesky uses a create-only record key derived from the original draft. Mastodon uses an idempotency header with a server-limited retention window. The other adapters use the draft UUID to correlate uncertain outcomes. The caller owns the persisted draft and reconciliation after an ambiguous result.
- **Scope.** The common API covers text publishing, single-post and paginated retrieval, replies, media publishing, and provider-supported engagement. Adapters select provider-specific upload and polling steps. The account-aware capability set reflects known OAuth grants.
- **Live acceptance.** Use a signed host app and test accounts to verify native browser sign-in, Keychain persistence across relaunch, authenticated publish/read/engagement, and provider-side revocation. The mock suite exercises wire behavior without credentials.
