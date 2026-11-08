# Dependencies and notices

SocialKit is MIT licensed and has no third-party Swift package dependencies or vendored source. It uses Apple’s Foundation, CryptoKit and Security frameworks. The SwiftUI connection example uses AuthenticationServices.

| Project evaluated | License and maintenance snapshot | Decision |
| --- | --- | --- |
| [OpenCore Social SDK](https://github.com/opencoredev/social-sdk) | MIT. The public repository lists active development and a v0.5.0 release. | Its capability checks, explicit publish outcomes and mock backend informed the design. The package targets server-side TypeScript. |
| [ATProtoKit](https://swiftpackageindex.com/MasterJ93/ATProtoKit) | MIT. The package index listed a recent 0.34.1 release and three dependencies at review time. | It has typed AT Protocol clients and models. The initial adapter needs only a small subset of XRPC and controls its own trusted PDS, credential lifecycle and write reconciliation. Reevaluate for AT Protocol OAuth or a broader protocol surface. |
| [TootSDK](https://github.com/TootSDK/TootSDK) | BSD-3-Clause. The repository has recent [versioned releases](https://github.com/TootSDK/TootSDK/releases). | It provides broad Fediverse API coverage. The initial Mastodon surface is small and the SDK owns the S256/state callback checks and publishing semantics. Reevaluate for media or wider Fediverse support. |

Provider request and response formats follow the [Bluesky API docs](https://docs.bsky.app/docs/api) and the [Mastodon API docs](https://docs.joinmastodon.org/methods/). The CI workflow uses GitHub’s [checkout action](https://github.com/actions/checkout) (MIT), a build-time tool.
