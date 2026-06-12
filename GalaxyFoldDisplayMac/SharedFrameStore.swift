import Foundation

@MainActor
final class SharedFrameStore {
    private(set) var latestFrame: Data?
    private(set) var frameDate: Date?

    func update(frame: Data) {
        latestFrame = frame
        frameDate = Date()
    }

    func snapshot() -> (frame: Data?, date: Date?) {
        (latestFrame, frameDate)
    }
}
