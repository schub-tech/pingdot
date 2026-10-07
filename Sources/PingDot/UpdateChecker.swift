#if !APP_STORE
import Foundation

/// Once a day: is there a newer release on GitHub? Shows up as one line in the
/// menu — no pop-up, no download, no install.
///
/// Only in the GitHub / Homebrew build. The App Store build is compiled with
/// `-D APP_STORE`, so this file is empty there: App Store apps must update through
/// the App Store and may not point anywhere else.
final class UpdateChecker {
    static let releasesPage = URL(string: "https://github.com/schub-tech/pingdot/releases/latest")!
    private static let latestRelease = URL(string: "https://api.github.com/repos/schub-tech/pingdot/releases/latest")!
    private static let interval: TimeInterval = 24 * 60 * 60

    /// Set when GitHub has a newer version than the running one.
    private(set) var availableVersion: String?
    var onChange: (() -> Void)?

    private var timer: Timer?

    func start() {
        stop()
        guard Settings.shared.checkForUpdates else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if availableVersion != nil {
            availableVersion = nil
            onChange?()
        }
    }

    private func check() {
        var request = URLRequest(url: Self.latestRelease, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            // Offline, rate-limited, no release yet: say nothing and try tomorrow.
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let release = try? JSONDecoder().decode(Release.self, from: data),
                  !release.draft, !release.prerelease else { return }
            let latest = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            DispatchQueue.main.async {
                guard let self, Settings.shared.checkForUpdates else { return }
                let newer = Self.isVersion(latest, newerThan: Self.currentVersion) ? latest : nil
                guard newer != self.availableVersion else { return }
                self.availableVersion = newer
                self.onChange?()
            }
        }.resume()
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Numeric, component by component: 0.10.0 > 0.9.1, and 0.1 == 0.1.0.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let lhs = a.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", draft, prerelease
        }
    }
}
#endif
