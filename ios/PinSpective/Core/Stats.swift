import Foundation

enum Stats {
    static func median<T: BinaryFloatingPoint>(_ a: [T]) -> T {
        guard !a.isEmpty else { return T.nan }
        let s = a.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    static func mean(_ a: [Double]) -> Double {
        guard !a.isEmpty else { return .nan }
        return a.reduce(0, +) / Double(a.count)
    }

    /// Sample standard deviation (n - 1).
    static func sd(_ a: [Double]) -> Double {
        guard a.count >= 2 else { return 0 }
        let m = mean(a)
        return sqrt(a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(a.count - 1))
    }

    /// Median absolute deviation scaled to be a consistent estimator of sigma for normal data.
    static func robustSigma(_ a: [Double]) -> Double {
        guard a.count >= 2 else { return 0 }
        let m = median(a)
        return 1.4826 * median(a.map { abs($0 - m) })
    }

    /// Nearest-rank percentile, p in 0...100.
    static func percentile(_ a: [Double], _ p: Double) -> Double {
        guard !a.isEmpty else { return .nan }
        let s = a.sorted()
        let rank = Int((p / 100 * Double(s.count)).rounded(.up))
        return s[min(max(rank, 1), s.count) - 1]
    }
}
