import CoreGraphics

enum ScreenEdgeProximity {
    /// A fast prefilter for the event tap. The Dock can auto-hide and can be
    /// magnified, so cached tile frames are not reliable enough to decide
    /// whether to consult Accessibility. A click near any display edge is
    /// cheap to check and covers a Dock pinned to any edge.
    static func isNearEdge(_ point: CGPoint, in bounds: CGRect, band: CGFloat) -> Bool {
        guard bounds.contains(point) else { return false }
        return point.x - bounds.minX <= band ||
            bounds.maxX - point.x <= band ||
            point.y - bounds.minY <= band ||
            bounds.maxY - point.y <= band
    }

    static func isNearAnyScreenEdge(_ point: CGPoint, band: CGFloat = 220) -> Bool {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &displays, &count) == .success else {
            // If the display list cannot be queried, prefer correctness over
            // skipping a possible Dock click.
            return true
        }
        for display in displays.prefix(Int(count)) {
            if isNearEdge(point, in: CGDisplayBounds(display), band: band) {
                return true
            }
        }
        return false
    }
}
