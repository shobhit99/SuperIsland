import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    private static let apiURL = URL(string: "https://api.github.com/repos/shobhit99/superisland/releases/latest")!
    private static let lastCheckedKey = "updateChecker.lastCheckedAt"
    private static let dailyInterval: TimeInterval = 86400

    enum CheckState {
        case idle
        case checking
        case upToDate
        case updateAvailable(latestVersion: String, releaseURL: URL, downloadURL: URL?)
        case failed(String)
    }

    @Published var checkState: CheckState = .idle

    private init() {}

    var lastCheckedAt: Date? {
        let ts = UserDefaults.standard.double(forKey: Self.lastCheckedKey)
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }

    /// Called on app launch — only fires if 24 h have elapsed since the last check.
    func checkIfDue() {
        if let last = lastCheckedAt, Date().timeIntervalSince(last) < Self.dailyInterval {
            return
        }
        Task { await performCheck() }
    }

    /// Manual "Check for Updates" button tap.
    func checkNow() {
        Task { await performCheck() }
    }

    private func performCheck() async {
        if case .checking = checkState { return }
        checkState = .checking

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckedKey)

        do {
            var request = URLRequest(url: Self.apiURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

            let (data, _) = try await URLSession.shared.data(for: request)

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let htmlURL = json["html_url"] as? String,
                  let releaseURL = URL(string: htmlURL) else {
                checkState = .failed("Invalid response from GitHub.")
                return
            }

            let assets = json["assets"] as? [[String: Any]] ?? []
            let dmgAsset = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
            let downloadURL = (dmgAsset?["browser_download_url"] as? String).flatMap { URL(string: $0) }

            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            if isNewer(latestVersion, than: currentVersion) {
                checkState = .updateAvailable(latestVersion: latestVersion, releaseURL: releaseURL, downloadURL: downloadURL)
            } else {
                checkState = .upToDate
            }
        } catch {
            checkState = .failed("Could not reach GitHub.")
        }
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").compactMap { Int($0) }
        let b = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
    }
}
