import CoreGraphics

enum FinderDesktopCoordinateSpace {
    static func finderPosition(
        for screenPoint: CGPoint,
        primaryScreenFrame: CGRect,
        screenFrames: [CGRect]
    ) -> CGPoint? {
        guard screenPoint.x.isFinite,
              screenPoint.y.isFinite,
              screenFrames.contains(where: { $0.contains(screenPoint) }) else {
            return nil
        }

        let position = CGPoint(
            x: screenPoint.x,
            y: primaryScreenFrame.maxY - screenPoint.y
        )
        guard position.x.isFinite, position.y.isFinite else { return nil }
        return position
    }

    static func containsFinderPosition(
        _ position: CGPoint,
        primaryScreenFrame: CGRect,
        screenFrames: [CGRect]
    ) -> Bool {
        guard position.x.isFinite, position.y.isFinite else { return false }
        let screenPoint = CGPoint(
            x: position.x,
            y: primaryScreenFrame.maxY - position.y
        )
        return screenFrames.contains(where: { $0.contains(screenPoint) })
    }
}
