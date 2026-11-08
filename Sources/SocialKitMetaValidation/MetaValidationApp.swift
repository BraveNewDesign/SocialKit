#if os(macOS)
import MetaValidationStorage
import SwiftUI

@main
struct MetaValidationApp: App {
    @State private var model = ValidationModel(
        store: MetaValidationCredentialStore(service: "com.bravenewdesign.socialkit.metavalidation")
    )

    var body: some Scene {
        Window("SocialKit Meta Validation", id: "meta-validation") {
            ValidationView(model: model)
                .frame(minWidth: 680, minHeight: 580)
        }
        .defaultSize(width: 820, height: 760)
    }
}
#else
@main
struct MetaValidationApp {
    static func main() {}
}
#endif
