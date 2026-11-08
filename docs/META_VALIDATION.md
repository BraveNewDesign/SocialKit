# Meta live validation

Run the native macOS harness from the repository root.

```sh
./scripts/run-meta-validation.sh
```

The script builds and opens `.build/MetaValidation.app`. It selects an available Apple Development identity or signs ad hoc when none is available. Use `DEVELOPMENT_IDENTITY` to pin the signing identity for later builds so macOS can recognize the app when it accesses its login Keychain entries. Ad hoc rebuilds can trigger Keychain access prompts. To test persistence, quit and reopen the existing bundle. Approve a Keychain prompt only for this app. **Remove Account** deletes its local entry. Revoke provider access separately in Meta. The credential-free `SocialKitExample` remains available for simulated checks.

Start with **Development token**. Copy the token directly from Meta into the app’s masked field. Clear your clipboard after pasting. Enter expiry or confirmed scopes only if Meta supplied them. Keep tokens, authorization codes, App Secrets and raw API responses out of chat, terminal arguments, screenshots, issue reports and repository files. The harness shows decoded summaries, identifiers and sanitized errors.

## 1. Facebook Pages

1. In [Meta for Developers → My Apps](https://developers.facebook.com/apps/), create or open a development app with **Manage everything on your Page** and the Facebook Login configuration available to that app. Keep the app in development for this test. The Facebook account must hold a role on the app and have Facebook or task access to the test Page.
2. Open [Graph API Explorer](https://developers.facebook.com/tools/explorer/). Select your app under **Meta App**. Under **User or Page**, select **Get User Access Token**. Add `pages_show_list`, `pages_read_engagement` and `pages_read_user_content` under **Permissions**. Click **Generate Access Token**, sign in and grant the test Page when prompted. Use the resulting **User** token.
3. In the app, select **Facebook Pages → Development token**. Paste the token, click **Discover Pages**, select your test Page and click **Verify and Save Development Token**. The app reads user grants and obtains the selected Page credential. A Facebook User token expiration does not establish a Page token expiration.
4. Click **Check Profile**, then **List Posts**. Choose a known Page post and click **Get Post** and **List Comments or Replies**. For comment validation, choose a post that already has a comment. For a later write test, generate a fresh token with `pages_manage_posts` as well and use a Page where you have content creation access.

[Meta Graph API Explorer guide](https://developers.facebook.com/docs/graph-api/guides/explorer) · [Pages API setup](https://developers.facebook.com/docs/pages-api/getting-started/) · [User permissions reference](https://developers.facebook.com/docs/graph-api/reference/user/permissions/)

## 2. Threads

1. In **My Apps**, create or open an app with **Access the Threads API**. Under **Use cases → Access the Threads API → Customize → Permissions**, enable `threads_basic` and `threads_read_replies` for development testing. Add `threads_content_publish` when preparing a later write test.
2. Add your account under **App roles → Roles → Add People → Threads Tester**, or use **Add or Remove Threads Test Users** in the Threads settings. Accept the invitation in Threads under **Settings → Account → Website permissions → Invites**.
3. Return to **Use cases → Access the Threads API → Customize → Settings**. Under **User Token Generator**, click **Generate Access Token** for the tester and approve the listed scopes. In the harness select **Threads → Development token**, paste, optionally enter the grants shown by Meta, then click **Verify and Save Development Token**.
4. Click **Check Profile**, **List Posts**, choose one of your Threads posts, then click **Get Post** and **List Comments or Replies**. Choose a thread with an existing reply to exercise decoding.

[Meta Threads app setup](https://developers.facebook.com/docs/threads/get-started/create-an-app/) · [Meta Threads API collection](https://www.postman.com/meta/threads/documentation/dht3nzz/threads-api)

## 3. Instagram

1. Use an Instagram **Business** or **Creator** account. In **My Apps**, create or open an app with the Instagram management use case. Open **Use cases → Instagram → Customize → API setup with Instagram login**. Use `instagram_business_basic` and `instagram_business_manage_comments` for the reads. Enable `instagram_business_content_publish` for a later write test.
2. Under **Generate access tokens**, select **Add account**, sign in to the professional account and grant the requested access. If Meta asks for an Instagram Tester, invite that account from **App roles → Roles** and accept under Instagram **Apps and Websites → Tester Invites**. Return to **Generate access tokens**, click **Generate token** for the account and authorize.
3. In the harness select **Instagram → Development token**, paste the Instagram User token, optionally enter the grants shown by Meta and click **Verify and Save Development Token**.
4. Click **Check Profile**, **List Posts**, select a media ID and click **Get Post** and **List Comments or Replies**. Use a media item with a known comment.

[Meta Instagram Login setup](https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/get-started/) · [Meta Instagram API collection](https://www.postman.com/meta/instagram/documentation/6yqw8pt/instagram-api)

Meta may show different dashboard labels by app type or account eligibility. The setup above uses the developer role path. External accounts can require Advanced Access and App Review. For imported Threads and Instagram credentials, a successful profile request establishes that Meta accepted that token for the profile call. The grants and expiry fields show operator-confirmed metadata when entered, and **Unknown** otherwise.

## Confidential OAuth

Use **Confidential OAuth** only if you already control an authenticated HTTPS exchange service that implements SocialKit’s `ConfidentialOAuthExchange` contract. This repository provides the native client. Configure an exact HTTPS callback for each provider, including any path and trailing slash.

| Provider | Dashboard setting | Client ID to enter |
| --- | --- | --- |
| Facebook Pages | **Facebook Login → Settings** or the login use case’s **Customize → Settings**. Enable **Client OAuth Login** and **Web OAuth Login**. Add the URL to **Valid OAuth Redirect URIs**. | Meta App ID |
| Threads | **Access the Threads API → Customize → Settings → Redirect Callback URLs**. | Threads App ID from Threads settings |
| Instagram | **API setup with Instagram login → Set up Instagram business login → Business login settings → Valid OAuth Redirect URIs**. | Instagram App ID from Instagram setup |

Use the exact registered callback and a bridge URL you trust. The system browser uses an HTTPS host/path callback on macOS 14.4 or later. For HTTPS callback delivery, sign for the app identifier `com.bravenewdesign.socialkit.metavalidation` with the Associated Domains capability and entitlement entry `webcredentials:<callback-host>`. Serve `/.well-known/apple-app-site-association` over HTTPS on that host with the signed application identifier in `webcredentials.apps`. Keep the callback path dedicated to OAuth and exclude its query from server logs. [Apple Associated Domains setup](https://developer.apple.com/documentation/xcode/supporting-associated-domains)

Keep the signing files outside the repository. Use the matching development identity, entitlements file and provisioning profile when building the OAuth-capable bundle.

```sh
DEVELOPMENT_IDENTITY="Apple Development: Your Name (TEAMID)" \
ASSOCIATED_DOMAINS_ENTITLEMENTS="/absolute/path/to/MetaValidation.entitlements" \
DEVELOPMENT_PROVISIONING_PROFILE="/absolute/path/to/MetaValidation.provisionprofile" \
./scripts/run-meta-validation.sh
```

In the app, select **Confidential OAuth**, enter the public App ID, exact HTTPS callback, trusted HTTPS bridge base URL and masked bridge bearer credential. Enter the target Page ID for Facebook. Leave **Request publishing permission** off for the read-only run, click **Authorize in Browser**, and approve the listed scopes. The Facebook OAuth adapter requires a Page with a content creation task. The development import also supports Pages with read-only access.

The bridge must authenticate the operator, authorize the provider, allowlist the client and exact redirect, exchange each code once, and keep each provider App Secret on the service. Use the provider’s token endpoint for its app type. The service must return only verified grants and expiry when it knows them. Keep codes and credentials out of service access and error logs.

- `POST /oauth/exchange` sends JSON fields `platform`, `code` and `redirect_uri`.
- `POST /oauth/refresh` sends `platform` and `refresh_token` if an adapter uses broker refresh.
- Platform values are `facebookPages`, `threads` and `instagram`. The response uses `access_token`, optional `refresh_token`, optional ISO-8601 `expires_at`, and optional string array `granted_scopes`.
- Both requests use the first-party bridge bearer credential entered into the masked field. The bridge credential is held in memory for the connection. Provider credentials are saved to Keychain.
- The client requires HTTPS and rejects redirects. For a local confidential service, use a trusted HTTPS development host and a Meta-accepted registered callback. Threads’ official sample uses a mapped hostname with TLS. Browser and service behavior still need an end-to-end test. Dashboard-issued tokens let you exercise API reads without provisioning a bridge.

[Meta Threads sample and redirect setup](https://github.com/fbsamples/threads_api)

## Checklist

Local results

| Check | Result |
| --- | --- |
| Debug test build and release build with warnings treated as errors | Pass |
| Signed macOS launch, provider picker and masked connection fields | Pass |
| Adapter and client fixtures, including Meta profiles, permissions, expired tokens and cancelled connection | Pass |
| Confidential bridge request and response fixtures | Pass |
| Synthetic credential persistence and removal using the macOS login Keychain | Pass |
| Credential-free seven-provider example | Pass |

Authenticated live status is **Pending authorization**. Empty collections are valid responses, but use known posts and comments to verify mapping.

| Check | Facebook Pages | Threads | Instagram |
| --- | --- | --- | --- |
| Select a Page or resolve account identity | Pending | Pending | Pending |
| Profile and token acceptance | Pending | Pending | Pending |
| First page of posts and post by ID | Pending | Pending | Pending |
| First page of comments or replies | Pending | Pending | Pending |
| Reopen app and recheck saved account | Pending | Pending | Pending |
| Restricted token or missing permission | Pending | Pending | Pending |
| Expired or revoked token | Pending | Pending | Pending |
| Remove local account and relaunch | Pending | Pending | Pending |
| Browser cancellation with configured bridge | Pending | Pending | Pending |
| Optional confirmed publish | Pending | Pending | Pending |

- **Missing permissions.** Connect a token with basic read permission and omit the comment or reply permission. Confirm the capability is unavailable when grants are known, or that Meta denies the attempted read when grants are unknown. For Facebook, use a new token and decline/remove `pages_read_user_content`.
- **Expiration.** For a known expired development token, enter its actual past expiry and confirm the app rejects it. To test provider-side rejection, revoke a disposable test authorization in Meta, then click **Check Profile** using the old saved entry. Reauthorize and reconnect before further tests.
- **Cancellation.** Start **Authorize in Browser** with a configured bridge and dismiss the system browser or click **Cancel** in the harness. Confirm the saved account list is unchanged and the result is **Cancelled**.
- **Persistence and removal.** Quit and reopen the same signed bundle, select the saved account and click **Check Profile**. Choose **Remove Account → Remove from Keychain**, quit and reopen again, and confirm the entry stays removed.
- **Optional publish.** Use a designated test account and a distinctive draft. For Instagram, supply a directly accessible public HTTPS JPEG URL without credentials or query parameters. Check the profile, enable publishing controls, click **Review Post…**, verify the exact account and content, then click **Publish Now** only when you want the real post created. Verify the post in Meta and by ID in the harness. If the outcome is uncertain, inspect the provider feed before another attempt, including after restarting the app.

## Provider findings

- Facebook Page discovery uses the Facebook User token. The selected Page token is stored for Page operations. Permission status is read from Facebook’s permissions endpoint. Page access and the role on the Page can still limit individual calls.
- Threads and Instagram use their own User tokens and profile endpoints. Requested OAuth scopes alone do not establish grants. A bridge can return grant metadata when it verifies it.
- Instagram publishing uses a fetched media URL. The harness exercises one public JPEG with an optional caption. Threads and Facebook publishing checks use text.
- Fixture tests exercise decoding and provider error handling. No authenticated provider responses or live model mismatches have been observed yet. Record any mismatch by provider, endpoint, HTTP status, Graph error code if available, and the missing or mismatched field. Use synthetic values in any committed regression fixture.
