import AppKit
import Combine
import Foundation

/// Pure version comparison, kept outside the main-actor checker so the
/// self-test can exercise it without starting a network task.
enum UpdateVersion {
    static func numbers(in value: String) -> [Int]? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" {
            text.removeFirst()
        }
        if let suffix = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            text = String(text[..<suffix])
        }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isNumber }),
                  let number = Int(part) else {
                return nil
            }
            numbers.append(number)
        }
        return numbers
    }

    /// Returns true only when `candidate` is a strictly newer numeric version.
    /// Unparseable versions (including `dev` builds) never prompt.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidateParts = numbers(in: candidate),
              let currentParts = numbers(in: current) else {
            return false
        }

        let count = max(candidateParts.count, currentParts.count)
        for index in 0..<count {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart {
                return candidatePart > currentPart
            }
        }
        return false
    }
}

/// Manual update check against the static version feed on the Pages site.
/// Nothing runs at launch and no identifier is sent; the feed is only fetched
/// when the user asks from Settings or the menu.
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case failed(String)
    }

    private struct Feed: Decodable {
        let version: String
        let url: String?
        let download: String?
    }

    static let shared = UpdateChecker()

    @Published private(set) var state: State = .idle
    @Published private(set) var latestVersion = ""
    @Published private(set) var lastChecked: Date?

    private let feedURL = URL(string: "https://peterhindes.github.io/faster-spaces/latest.json")!
    private let fallbackReleaseURL = URL(string: "https://github.com/PeterHindes/faster-spaces/releases/latest")!
    private var releasePage: URL?
    private var task: URLSessionDataTask?
    private var completion: ((State) -> Void)?

    func check(completion: ((State) -> Void)? = nil) {
        guard state != .checking else { return }

        self.completion = completion
        state = .checking
        releasePage = nil

        var components = URLComponents(url: feedURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))
        ]
        var request = URLRequest(url: components?.url ?? feedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        task?.cancel()
        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor [weak self] in
                self?.finish(data: data, response: response, error: error)
            }
        }
        task?.resume()
    }

    func openReleasePage() {
        NSWorkspace.shared.open(releasePage ?? fallbackReleaseURL)
    }

    private func finish(data: Data?, response: URLResponse?, error: Error?) {
        task = nil
        let result: State

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            result = .failed("The update server returned HTTP \(http.statusCode).")
        } else if error != nil {
            result = .failed("Couldn't reach the update server. Check your connection and try again.")
        } else if let data {
            do {
                let feed = try JSONDecoder().decode(Feed.self, from: data)
                let remote = feed.version.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !remote.isEmpty else {
                    result = .failed("The update feed did not include a version.")
                    apply(result)
                    return
                }

                latestVersion = remote
                lastChecked = Date()
                releasePage = feed.url.flatMap(URL.init(string:)) ?? fallbackReleaseURL

                if UpdateVersion.isNewer(remote, than: AppInfo.version) {
                    result = .available(version: remote)
                    Log.info("Update check: \(remote) available (running \(AppInfo.version))")
                } else {
                    result = .upToDate
                    Log.info("Update check: up to date (running \(AppInfo.version), feed \(remote))")
                }
            } catch {
                result = .failed("Couldn't read the update feed.")
                Log.error("Update check: invalid feed")
            }
        } else {
            result = .failed("The update server returned an empty response.")
        }

        apply(result)
    }

    private func apply(_ result: State) {
        state = result
        if case .failed(let message) = result {
            Log.error("Update check failed: \(message)")
        }
        let handler = completion
        completion = nil
        handler?(result)
    }
}
