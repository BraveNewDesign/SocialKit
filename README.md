# SocialKit

SocialKit is an MIT-licensed Swift 6 package for integrating social accounts into native Apple apps. It supports macOS 14+ and targets iOS 17+. It has no third-party package dependencies.

| Provider | Connect | Text posts | Get a post | Engagement |
| --- | --- | --- | --- | --- |
| Bluesky | App password and explicit session refresh | Yes | Yes | Like |
| Mastodon 4.3+ | Browser OAuth with S256 PKCE | Yes | Yes | Favourite and unfavourite |

Create a `SocialClient` for each adapter and share a credential store across them. Each client can manage multiple accounts. Check `client.capabilities` before exposing an action. Media, analytics, timelines, and scheduling are outside the initial API.

Add the repository as a Swift package dependency and link the `SocialKit` library product. To try it locally without a provider account:

```sh
swift build
swift test
swift run SocialKitExample
```

See [Setup and usage](docs/SETUP.md) for authentication, publishing, and recovery. [Design](docs/DESIGN.md) covers the shared interfaces. [Expansion](docs/EXPANSION.md) compares X, Threads, Instagram, Facebook Pages, and LinkedIn. [Dependency notes](docs/DEPENDENCIES.md) record the libraries evaluated.

The provider suites use scripted HTTP. Live sign-in and authenticated requests need provider accounts. The Keychain path needs a signed app.
