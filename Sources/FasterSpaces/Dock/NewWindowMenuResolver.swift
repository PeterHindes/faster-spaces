import AppKit
import ApplicationServices
import Foundation

struct MenuCandidate: Equatable {
    let title: String
    let keyEquivalent: String
    let commandModifiers: UInt32
    let enabled: Bool
    let hasChildren: Bool
    let path: [String]
}

enum NewWindowMenuScoring {
    static let minimumAcceptedScore = 50

    static func score(_ candidate: MenuCandidate) -> Int? {
        guard candidate.enabled, !candidate.hasChildren else { return nil }

        let title = candidate.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !title.isEmpty else { return nil }

        var score = 0
        let containsNew = title.contains("new")
        let containsWindow = title.contains("window")

        if containsNew && containsWindow {
            score += 200
        } else if title == "new" {
            score += 90
        } else if title.hasPrefix("new ") {
            score += 45
        }

        if candidate.keyEquivalent.lowercased() == "n" &&
            (candidate.commandModifiers & UInt32(1 << 3)) == 0 {
            score += 30
        }

        if candidate.path.contains(where: { $0.caseInsensitiveCompare("File") == .orderedSame }) {
            score += 10
        }

        if title.contains("tab") || title.contains("folder") || title.contains("group") {
            score -= 90
        }

        return score >= minimumAcceptedScore ? score : nil
    }

    static func best(in candidates: [MenuCandidate]) -> MenuCandidate? {
        candidates
            .compactMap { candidate -> (MenuCandidate, Int)? in
                guard let score = score(candidate) else { return nil }
                return (candidate, score)
            }
            .max { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.title.count > rhs.0.title.count
                }
                return lhs.1 < rhs.1
            }?
            .0
    }
}

final class NewWindowMenuResolver {
    struct Match {
        let element: AXUIElement
        let title: String
        let score: Int
    }

    private struct CachedMatch {
        let element: AXUIElement
        let title: String
        let score: Int
    }

    private var cache: [pid_t: CachedMatch] = [:]

    func match(for application: AXUIElement, pid: pid_t) -> Match? {
        if let cached = cache[pid], isUsable(cached.element) {
            return Match(element: cached.element, title: cached.title, score: cached.score)
        }

        guard let menuBar = AX.element(application, AXAttr.menuBar) else {
            Log.debug("No menu bar for pid \(pid)")
            return nil
        }

        let deadline = CACurrentMediaTime() + 0.65
        var candidates: [(MenuCandidate, AXUIElement)] = []
        var visited = 0
        scan(element: menuBar,
             depth: 0,
             path: [],
             deadline: deadline,
             visited: &visited,
             candidates: &candidates)

        guard let best = NewWindowMenuScoring.best(in: candidates.map(\.0)),
              let element = candidates.first(where: { $0.0 == best })?.1 else {
            Log.debug("No New Window menu item found for pid \(pid); scanned \(visited) elements")
            return nil
        }

        guard let score = NewWindowMenuScoring.score(best) else { return nil }
        cache[pid] = CachedMatch(element: element, title: best.title, score: score)
        Log.debug("Resolved menu item '\(best.title)' for pid \(pid)")
        return Match(element: element, title: best.title, score: score)
    }

    func invalidate(pid: pid_t) {
        cache.removeValue(forKey: pid)
    }

    func clear() {
        cache.removeAll()
    }

    private func isUsable(_ element: AXUIElement) -> Bool {
        let role = AX.string(element, AXAttr.role) ?? ""
        guard role == (kAXMenuItemRole as String) else { return false }
        return AX.bool(element, AXAttr.enabled) ?? true
    }

    private func scan(element: AXUIElement,
                      depth: Int,
                      path: [String],
                      deadline: CFTimeInterval,
                      visited: inout Int,
                      candidates: inout [(MenuCandidate, AXUIElement)]) {
        guard depth <= 7,
              visited < 5_000,
              CACurrentMediaTime() < deadline else {
            return
        }
        visited += 1

        let role = AX.string(element, AXAttr.role) ?? ""
        let title = AX.string(element, AXAttr.title) ?? ""

        if role == (kAXMenuItemRole as String) {
            let children = AX.elements(element, AXAttr.children)
            if !children.isEmpty {
                for child in children {
                    scan(element: child,
                         depth: depth + 1,
                         path: path + [title],
                         deadline: deadline,
                         visited: &visited,
                         candidates: &candidates)
                }
                return
            }

            let candidate = MenuCandidate(
                title: title,
                keyEquivalent: AX.string(element, AXAttr.menuItemCmdChar) ?? "",
                commandModifiers: UInt32(AX.int(element, AXAttr.menuItemCmdModifiers) ?? 0),
                enabled: AX.bool(element, AXAttr.enabled) ?? true,
                hasChildren: false,
                path: path
            )
            if NewWindowMenuScoring.score(candidate) != nil {
                candidates.append((candidate, element))
            }
            return
        }

        let nextPath = title.isEmpty ? path : path + [title]
        for child in AX.elements(element, AXAttr.children) {
            scan(element: child,
                 depth: depth + 1,
                 path: nextPath,
                 deadline: deadline,
                 visited: &visited,
                 candidates: &candidates)
        }
    }
}
