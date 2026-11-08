#if os(macOS)
import MetaValidationOAuth
import SocialKit
import SwiftUI

struct ValidationView: View {
    @Bindable var model: ValidationModel

    @State private var provider = Provider.facebook
    @State private var method = ConnectionMethod.development
    @State private var token = ""
    @State private var reportedScopes = ""
    @State private var knownExpiry = false
    @State private var expiration = Date()
    @State private var pageID = ""
    @State private var clientID = ""
    @State private var redirect = ""
    @State private var bridge = ""
    @State private var bridgeCredential = ""
    @State private var requestPublishing = false
    @State private var postID = ""
    @State private var showPublish = false
    @State private var draft = ""
    @State private var image = ""
    @State private var confirmation: PublishIntent?
    @State private var confirmRemoval = false

    private enum ConnectionMethod: String, CaseIterable, Identifiable {
        case development = "Development token"
        case oauth = "Confidential OAuth"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Provider") {
                    Picker("Meta integration", selection: $provider) {
                        ForEach(Provider.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                connection
                accountDetails
                if model.account != nil {
                    readChecks
                    publishing
                }
            }
            .formStyle(.grouped)
            .disabled(model.busy)

            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Latest result. \(model.status)")
                if model.canCancel { Button("Cancel") { model.cancel() } }
            }
            .padding()
        }
        .task { model.load(provider) }
        .onChange(of: provider) {
            clearConnectionFields()
            model.load(provider)
        }
        .onChange(of: method) { clearConnectionFields() }
        .onChange(of: model.selected) {
            postID = ""
            showPublish = false
            draft = ""
            image = ""
        }
        .confirmationDialog(
            "Publish a real post?",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            titleVisibility: .visible,
            presenting: confirmation
        ) { intent in
            Button("Publish Now") {
                model.publish(intent)
                draft = ""
                image = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: { intent in
            Text("Target: \(intent.account.username) (\(intent.account.remoteID)) on \(provider.rawValue)\n\n\(intent.draft.text)\(intent.image.map { "\n\n" + $0.absoluteString } ?? "")")
        }
        .confirmationDialog("Remove this local account?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove from Keychain", role: .destructive) { model.disconnect(provider) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved credential from this Mac. Manage authorization separately in Meta.")
        }
    }

    private var connection: some View {
        Section("Connect an account") {
            Picker("Connection method", selection: $method) {
                ForEach(ConnectionMethod.allCases) { Text($0.rawValue).tag($0) }
            }
            switch method {
            case .development:
                developmentFields
            case .oauth:
                oauthFields
            }
        }
    }

    @ViewBuilder private var developmentFields: some View {
        Text(provider == .facebook
             ? "Use a Facebook User access token from your own app. Discover Pages, then choose a Page and connect."
             : "Use a development access token issued for your own account and Meta app.")
            .foregroundStyle(.secondary)
        SecureField("Development access token", text: $token)
            .autocorrectionDisabled()
        if provider == .facebook {
            Button("Discover Pages") {
                model.discoverPages(OAuthToken(accessToken: trimmedToken, expiresAt: knownExpiry ? expiration : nil))
            }
            .disabled(trimmedToken.isEmpty)
            if !model.discoveredPages.isEmpty {
                Picker("Page", selection: $pageID) {
                    Text("Select a Page").tag("")
                    ForEach(model.discoveredPages) { page in
                        Text("\(page.username) (\(page.remoteID))").tag(page.remoteID)
                    }
                }
            }
        } else {
            TextField("Confirmed scopes (optional, comma-separated)", text: $reportedScopes)
            Text("Enter only scopes verified for this token in Meta. Leave blank if unknown.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Toggle("I know the token expiration", isOn: $knownExpiry)
        if knownExpiry { DatePicker("Expires", selection: $expiration) }
        Button("Verify and Save Development Token") {
            let scopes = Set(reportedScopes.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })
            let imported = OAuthToken(
                accessToken: trimmedToken, expiresAt: knownExpiry ? expiration : nil,
                grantedScopes: scopes.isEmpty ? nil : scopes
            )
            token = ""
            model.importToken(imported, provider: provider, pageID: pageID)
        }
        .disabled(trimmedToken.isEmpty || (provider == .facebook && pageID.isEmpty))
        .onChange(of: token) { _, newValue in
            if !newValue.isEmpty {
                pageID = ""
                model.clearDiscoveredPages()
            }
        }
    }

    @ViewBuilder private var oauthFields: some View {
        Text("Use your own trusted confidential exchange service. Enter the public App ID, exact registered HTTPS callback, and the HTTPS bridge base URL.")
            .foregroundStyle(.secondary)
        TextField("Meta App ID", text: $clientID)
        TextField("HTTPS redirect URI", text: $redirect)
        TextField("HTTPS bridge base URL", text: $bridge)
        SecureField("Bridge bearer credential", text: $bridgeCredential)
            .autocorrectionDisabled()
        if provider == .facebook { TextField("Target Facebook Page ID", text: $pageID) }
        Toggle("Request publishing permission", isOn: $requestPublishing)
        if #available(macOS 14.4, *) {
            Button("Authorize in Browser") {
                guard let callback = URL(string: redirect),
                      let origin = URL(string: bridge),
                      let exchange = try? MetaValidationOAuthBridge(endpoint: origin, bearerToken: bridgeCredential) else {
                    model.reportInvalidConfiguration()
                    return
                }
                bridgeCredential = ""
                model.connect(
                    provider, clientID: clientID, pageID: pageID, redirect: callback,
                    exchange: exchange, browser: MetaValidationOAuthBrowser.make(),
                    requestPublishing: requestPublishing
                )
            }
            .disabled(!canAuthorize)
        } else {
            Text("The HTTPS OAuth callback requires macOS 14.4 or later.").foregroundStyle(.secondary)
        }
    }

    private var accountDetails: some View {
        Section("Connected account") {
            Picker("Saved account", selection: $model.selected) {
                if model.accounts.isEmpty {
                    Text("No saved account").tag(nil as SocialAccount.ID?)
                }
                ForEach(model.accounts) { account in
                    Text("\(account.username) (\(account.remoteID))").tag(Optional(account.id))
                }
            }
            .onChange(of: model.selected) { _, newValue in
                if newValue != nil, !model.busy { model.selectAccount() }
            }
            if let account = model.account {
                LabeledContent("Token validity", value: model.validity)
                if let expiry = model.expiration {
                    LabeledContent("Reported expiration", value: expiry.formatted())
                } else {
                    LabeledContent("Reported expiration", value: "Unknown")
                }
                LabeledContent("Granted permissions", value: model.scopes.map {
                    $0.isEmpty ? "None" : $0.sorted().joined(separator: ", ")
                } ?? "Unknown")
                LabeledContent("Adapter capabilities", value: capabilityDescription)
                HStack {
                    Button("Check Profile") { model.checkProfile() }
                    Button("Remove Account", role: .destructive) { confirmRemoval = true }
                }
                .help("Local Keychain account \(account.remoteID)")
            }
        }
    }

    private var readChecks: some View {
        Section("Read-only checks") {
            Button("List Posts") { model.listPosts() }
                .disabled(!model.capabilities.contains(.listPosts))
            ForEach(model.posts) { post in
                Button {
                    postID = post.id
                } label: {
                    VStack(alignment: .leading) {
                        Text(post.id)
                        postSummary(post)
                    }
                }
                .buttonStyle(.borderless)
                .help("Use this post ID in the checks below")
            }
            TextField("Post ID", text: $postID)
            HStack {
                Button("Get Post") { model.fetchPost(cleanPostID) }
                    .disabled(cleanPostID.isEmpty || !model.capabilities.contains(.readPost))
                Button("List Comments or Replies") { model.listComments(cleanPostID) }
                    .disabled(cleanPostID.isEmpty || !model.capabilities.contains(.readReplies))
            }
            ForEach(model.comments) { comment in
                LabeledContent(comment.id) { postSummary(comment) }
            }
        }
    }

    private var publishing: some View {
        Section("Optional publishing check") {
            if let id = model.selected, model.uncertainAccounts.contains(id) {
                Text("Meta may have accepted the last post. Check the provider feed before proceeding.")
                Button("I Checked the Provider Feed") { model.acknowledgeReconciliation() }
            } else {
                Toggle("Enable publishing controls", isOn: $showPublish)
                if showPublish {
                    TextField(provider == .instagram ? "Caption" : "Post text", text: $draft, axis: .vertical)
                        .lineLimit(3...5)
                    if provider == .instagram {
                        TextField("Public HTTPS JPEG URL", text: $image)
                    }
                    Button("Review Post…") {
                        guard let account = model.account else { return }
                        confirmation = PublishIntent(account: account, draft: TextPost(text: draft), image: imageURL)
                    }
                    .disabled(!canReview)
                    Text("Publishing requires a verified profile, the publishing scope, and a final confirmation.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var canAuthorize: Bool {
        !clientID.isEmpty && !redirect.isEmpty && !bridge.isEmpty && !bridgeCredential.isEmpty
            && (provider != .facebook || !pageID.isEmpty)
    }

    private var canReview: Bool {
        guard model.selected != nil, model.verifiedAccount == model.selected,
              model.scopes?.contains(provider.publishScope) == true else { return false }
        if provider == .instagram { return model.capabilities.contains(.publishMedia) && imageURL != nil }
        return model.capabilities.contains(.publishText) && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var imageURL: URL? {
        guard provider == .instagram,
              let components = URLComponents(string: image), components.scheme == "https",
              components.host != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        return components.url
    }

    private var capabilityDescription: String {
        let names = model.capabilities.map(\.rawValue).sorted().joined(separator: ", ")
        if model.scopes == nil { return "Potential (scopes unknown) — \(names)" }
        return names.isEmpty ? "None" : names
    }

    private var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanPostID: String { postID.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func postSummary(_ post: SocialPost) -> some View {
        Text("\(post.text.count) characters · \(post.media.count) attachments · \(post.createdAt?.formatted() ?? "date unavailable")")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func clearConnectionFields() {
        model.clearDiscoveredPages()
        token = ""
        reportedScopes = ""
        knownExpiry = false
        pageID = ""
        clientID = ""
        redirect = ""
        bridge = ""
        bridgeCredential = ""
        requestPublishing = false
    }
}
#endif
