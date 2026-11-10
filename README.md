# SocialKit

SocialKit is an MIT-licensed Swift 6 package for integrating social accounts into native Apple apps. It supports macOS 14+ and targets iOS 17+. The package has zero third-party dependencies.

| Provider | Sign-in | Publish | Read | Engagement |
| --- | --- | --- | --- | --- |
| Bluesky | App password | Text | Single post and public author feed | Like |
| Mastodon 4.3+ | Browser OAuth with S256 PKCE | Text | Single post and account statuses | Favourite and unfavourite |
| Threads | OAuth with a confidential exchange | Text, image, and video by HTTPS URL | Posts and replies | Replies, moderation, and repost |
| Facebook Pages | Facebook Login and Page access token | Text | Page posts and comments | Comments and Page likes |
| Instagram | Instagram Login for professional accounts | Image, Reel, and carousel by HTTPS URL | Media and comments | Reply to and manage comments |
| LinkedIn | OAuth with a confidential exchange | Member or organization text and images | Posts and comments where authorized | Comments and reactions where authorized |
| X | Public-client OAuth 2.0 with S256 PKCE | Text, replies, and images | Post lookup and timelines | Likes and reposts |

Create one `SocialClient` per adapter and share a credential store across providers. Each client can manage multiple accounts. Use `capabilities(for:)` for account-aware discovery and handle provider permission errors when access depends on app review or account roles.

`SocialAccount` separates the selected publishing identity (`displayName`, `username`, and stable ID) from the authenticated member name for organization or Page connections. `SocialPost` can carry provider-returned author and reply context without requiring every adapter to supply it. Bluesky additionally supports `resolveMention(_:as:)`; place the returned DID with the exact UTF-8 byte range in `TextPost.mentions` to create a native AT Protocol mention facet. Other adapters do not claim native mention support through this API.

Add the repository as a Swift package dependency and link the `SocialKit` library product. The example and tests use scripted HTTP and require no account, API key, backend, or network.

```sh
swift build
swift test
swift run SocialKitExample
swift run SocialKitExample --platform instagram
```

See [Setup and usage](docs/SETUP.md) for credential storage and publishing recovery, [Platform setup and capabilities](docs/PLATFORMS.md) for permission and infrastructure requirements, and [Dependency notes](docs/DEPENDENCIES.md) for sources evaluated. Provider behavior is verified against mocked HTTP. Live account access and signed-app Keychain use require separate verification.

The optional `SocialKitUI` library product provides a SwiftUI connection button, publishing form, and operation result view. It takes your existing connection and publishing closures and shares the SDK’s cancellation and uncertain-write behavior. [SwiftUI integration](docs/SETUP.md#optional-swiftui-components) · [Adapter audit and verification](docs/AUDIT.md)

## Live Meta validation on macOS

Run `./scripts/run-meta-validation.sh` to open the native validation app for Facebook Pages, Threads and Instagram. Follow the [Meta setup and live checklist](docs/META_VALIDATION.md) to connect your own test accounts and run read-only checks.
