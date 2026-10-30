import CoreGraphics
import Foundation

struct DockTile: Equatable {
    let title: String
    let frame: CGRect
    let isRunning: Bool
    let bundleIdentifier: String?
    let applicationURL: URL?

    init(title: String,
         frame: CGRect,
         isRunning: Bool,
         bundleIdentifier: String? = nil,
         applicationURL: URL? = nil) {
        self.title = title
        self.frame = frame
        self.isRunning = isRunning
        self.bundleIdentifier = bundleIdentifier
        self.applicationURL = applicationURL
    }
}

struct DockSnapshot {
    let tiles: [DockTile]
    let capturedAt: CFTimeInterval

    static let empty = DockSnapshot(tiles: [], capturedAt: 0)

    var unionBounds: CGRect? {
        guard let first = tiles.first else { return nil }
        return tiles.dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }

    func tile(at point: CGPoint, slop: CGFloat) -> DockTile? {
        tiles.first { tile in
            tile.frame.insetBy(dx: -slop, dy: -slop).contains(point)
        }
    }

    func mightContainTile(at point: CGPoint, slop: CGFloat) -> Bool {
        tile(at: point, slop: slop) != nil
    }
}
