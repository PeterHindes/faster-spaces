import Combine
import Foundation

/// Observable status for the New Window Plz–style Dock click controller. The
/// controller runs on its own queues, so every write here is hopped to main.
final class DockStatusModel: ObservableObject {
    static let shared = DockStatusModel()

    @Published var monitoringActive = false
    @Published var eventTapDescription = "Not running"
    @Published var lastFailure: String?
    @Published var lastAction: String?
    @Published var cachedDockTileCount = 0
    @Published var isPickingApp = false

    private init() {}
}
