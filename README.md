# SocialKit

SocialKit is an MIT-licensed Swift 6 package for integrating social accounts into native Apple apps. It supports macOS 14+ and targets iOS 17+. The package has zero third-party dependencies.

| Provider | Sign-in | Publish | Read | Engagement |
| --- | --- | --- | --- | --- |
| Bluesky | App password | Text | Single post | Like |
| Mastodon 4.3+ | Browser OAuth with S256 PKCE | Text | Single post | Favourite and unfavourite |
| Threads | OAuth with a confidential exchange | Text, image, and video by HTTPS URL | Posts and replies | Replies, own-reply deletion, and repost |
| Facebook Pages | Facebook Login and Page access token | Text | Page posts and comments | Comments and Page likes |
| Instagram | Instagram Login for professional accounts | Image and Reel by HTTPS URL | Media and comments | Reply to and manage comments |
| LinkedIn | OAuth with a confidential exchange | Member or organization text and single image | Posts and comments where authorized | Comments and reactions where authorized |
| X | Public-client OAuth 2.0 with S256 PKCE | Text and replies | Post lookup and timelines | Likes and reposts |

Create one `SocialClient` per adapter and share a credential store across providers. Each client can manage multiple accounts. Use `capabilities(for:)` for account-aware discovery and handle provider permission errors when access depends on app review or account roles.

Add the repository as a Swift package dependency and link the `SocialKit` library product. The example and tests use scripted HTTP and require no account, API key, backend, or network.

```sh
swift build
swift test
swift run SocialKitExample
```

See [Setup and usage](docs/SETUP.md) for credential storage and publishing recovery, [Platform setup and capabilities](docs/PLATFORMS.md) for permission and infrastructure requirements, and [Dependency notes](docs/DEPENDENCIES.md) for sources evaluated. Provider behavior is verified against mocked HTTP. Live account access and signed-app Keychain use require separate verification.
