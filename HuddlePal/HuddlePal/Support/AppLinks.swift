import Foundation

/// The public pages on huddlepals.com and the support address. App Review
/// expects the privacy policy and a way to reach us inside the app
/// (guidelines 5.1.1(i) and 1.2): Profile → About links to all of them.
enum AppLinks {
    static let website = URL(string: "https://huddlepals.com")!
    static let privacyPolicy = URL(string: "https://huddlepals.com/privacy")!
    static let support = URL(string: "https://huddlepals.com/support")!
    static let contactEmail = "hello@huddlepals.com"
    static let contact = URL(string: "mailto:\(contactEmail)")!
}
