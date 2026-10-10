import Foundation
import ImageServerAPI
import ImageServerModels

/// Which models stay in memory (Engines-PRD ENG-3): one heavy model at a time, nothing loaded that won't fit, and
/// idle models released. Without it, models from earlier jobs pile up until a big load fails in Metal and takes the
/// engine down (seen in R1b: Qwen-Image-Edit still resident, then Qwen-Image Flash).
///
/// - **One heavy slot.** Loading a heavy model (≥ `heavyBytes`) first evicts every other heavy one.
/// - **Machine fit.** If the runtime says a model won't fit, everything idle is evicted before it loads.
/// - **Keep-warm.** A model unused for `keepWarm` is released; one of `bigBytes` or more after `bigKeepWarm`.
/// Models a running job is using are never evicted.
public actor Residency {
    public struct Policy: Sendable {
        public var heavyBytes: UInt64 = 12 << 30
        public var bigBytes: UInt64 = 20 << 30
        public var keepWarm: Duration = .seconds(600)
        public var bigKeepWarm: Duration = .seconds(180)
        public var sweepInterval: Duration = .seconds(30)
        public init() {}
    }

    let runner: any ModelRunner
    let router: any ModelRouter
    let policy: Policy
    private var footprints: [String: UInt64] = [:]
    private var lastUse: [String: ContinuousClock.Instant] = [:]
    private var inUse: [String: Int] = [:]
    private var sweeper: Task<Void, Never>?
    /// What was evicted and why, newest last (for logs and tests).
    public private(set) var evictions: [(package: String, reason: String)] = []

    public init(runner: any ModelRunner, router: any ModelRouter, policy: Policy = Policy()) {
        self.runner = runner; self.router = router; self.policy = policy
    }

    deinit { sweeper?.cancel() }

    /// Makes room for `route` and marks it in use. Call before preparing it; balance with `release`.
    public func admit(_ route: RoutedModel) async {
        await loadFootprints()
        let mine = route.packageID
        inUse[mine, default: 0] += 1
        lastUse[mine] = .now
        startSweeping()
        let size = route.footprintBytes ?? footprints[mine] ?? 0
        if size >= policy.heavyBytes {
            for package in await runner.residentPackages() where package != mine && idle(package) && footprint(package) >= policy.heavyBytes {
                await evict(package, reason: "one heavy model at a time (loading \(route.id.rawValue))")
            }
        }
        if let fit = await runner.machineFit(route), !fit.fits {
            for package in await runner.residentPackages() where package != mine && idle(package) {
                await evict(package, reason: "making room: \(fit.message)")
            }
        }
    }

    /// Marks `route` no longer in use by the job that admitted it.
    public func release(_ route: RoutedModel) {
        let package = route.packageID
        inUse[package] = max(0, (inUse[package] ?? 1) - 1)
        lastUse[package] = .now
    }

    /// Releases models idle past their keep-warm time.
    public func sweep() async {
        let now = ContinuousClock.Instant.now
        for package in await runner.residentPackages() where idle(package) {
            guard let used = lastUse[package] else { lastUse[package] = now; continue }
            let limit = footprint(package) >= policy.bigBytes ? policy.bigKeepWarm : policy.keepWarm
            if now - used >= limit { await evict(package, reason: "idle for \(limit)") }
        }
    }

    private func idle(_ package: String) -> Bool { (inUse[package] ?? 0) == 0 }
    private func footprint(_ package: String) -> UInt64 { footprints[package] ?? 0 }

    private func evict(_ package: String, reason: String) async {
        await runner.evict(packageID: package)
        lastUse[package] = nil
        evictions.append((package, reason))
        print("residency: released \(package) — \(reason)")
    }

    private func loadFootprints() async {
        guard footprints.isEmpty else { return }
        for model in await router.registeredModels() { footprints[model.packageID] = model.footprintBytes ?? 0 }
    }

    private func startSweeping() {
        guard sweeper == nil else { return }
        let interval = policy.sweepInterval
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.sweep()
            }
        }
    }
}
