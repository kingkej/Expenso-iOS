import CoreMotion
import Foundation
import Observation

enum GlassAppearanceSettings {
    static let motionKey = "appearance.motionReflections"
}

@MainActor
protocol ReflectionMotionSource: AnyObject {
    var isAvailable: Bool { get }
    func start(_ receive: @escaping @Sendable (Double?, Double?) async -> Void)
    func stop()
}

@MainActor
private final class DeviceReflectionMotion: ReflectionMotionSource {
    private let manager = CMMotionManager()
    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start(_ receive: @escaping @Sendable (Double?, Double?) async -> Void) {
        manager.deviceMotionUpdateInterval = 1.0 / 15.0
        // Gravity only: no heading, location, recording or remote processing.
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { motion, error in
            let x = error == nil ? motion?.gravity.x : nil
            let z = error == nil ? motion?.gravity.z : nil
            Task { await receive(x, z) }
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}

/// One sensor shared by visible decorative rims. Only the rim observes these values.
@MainActor @Observable
final class GlassReflectionMotion {
    static let shared = GlassReflectionMotion()
    private(set) var x = 0.0
    private(set) var y = 0.0
    @ObservationIgnored private let source: any ReflectionMotionSource
    @ObservationIgnored private var clients = Set<UUID>()
    @ObservationIgnored private var generation: UUID?

    init(source: (any ReflectionMotionSource)? = nil) {
        self.source = source ?? DeviceReflectionMotion()
    }

    func setActive(_ active: Bool, client: UUID) {
        if active { clients.insert(client) } else { clients.remove(client) }
        guard !clients.isEmpty else { stop(); return }
        guard generation == nil, source.isAvailable else { return }
        let token = UUID()
        generation = token
        source.start { [weak self] x, y in
            await self?.receive(x: x, y: y, generation: token)
        }
    }

    private func receive(x: Double?, y: Double?, generation token: UUID) {
        guard generation == token, !clients.isEmpty else { return }
        guard let x, let y, x.isFinite, y.isFinite else { stop(); return }
        // Low-pass filtering and bounded travel prevent jitter and large sweeps.
        let nextX = self.x + (min(1, max(-1, x)) * 0.18 - self.x) * 0.2
        let nextY = self.y + (min(1, max(-1, y)) * 0.14 - self.y) * 0.2
        if abs(nextX - self.x) > 0.001 || abs(nextY - self.y) > 0.001 {
            self.x = nextX
            self.y = nextY
        }
    }

    private func stop() {
        if generation != nil { source.stop() }
        generation = nil
        x = 0
        y = 0
    }
}
