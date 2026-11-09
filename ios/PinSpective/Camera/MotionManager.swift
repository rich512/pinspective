import CoreMotion
import simd

/// Gravity direction from Core Motion's sensor fusion (accelerometer + gyroscope).
/// Used only for (1) aligning the ROI so the plumb flagstick is vertical and (2) the small
/// elevation-angle correction in X = H / (tan e_top - tan e_base). It is never used to
/// measure distance or baseline on its own.
final class MotionManager {
    private let mm = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var g = SIMD3<Double>(0, -1, 0)
    private var haveData = false

    var available: Bool { mm.isDeviceMotionAvailable }

    func start() {
        guard mm.isDeviceMotionAvailable, !mm.isDeviceMotionActive else { return }
        queue.maxConcurrentOperationCount = 1
        mm.deviceMotionUpdateInterval = 1.0 / 100.0
        mm.startDeviceMotionUpdates(to: queue) { [weak self] m, _ in
            guard let self, let m else { return }
            let v = SIMD3<Double>(m.gravity.x, m.gravity.y, m.gravity.z)
            self.lock.lock(); self.g = v; self.haveData = true; self.lock.unlock()
        }
    }

    func stop() { mm.stopDeviceMotionUpdates() }

    /// Latest gravity vector in device coordinates (units of g), or nil before the first update.
    func gravity() -> SIMD3<Double>? {
        lock.lock(); defer { lock.unlock() }
        return haveData ? g : nil
    }
}
