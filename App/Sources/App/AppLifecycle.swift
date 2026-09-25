import UIKit
import Combine

/// (lifecycle pass) The app's lifecycle, fed into the engine. The bundle's `document` always read
/// "visible" and `navigator.onLine` always true, so none of upstream's lifecycle hooks ever ran
/// on the TV:
/// - profile-sync/scheduler.ts pushes its queue on hidden (not 2.5 s later, after tvOS may have
///   suspended the app) and pulls when it comes back more than five minutes stale;
/// - account/session-refresh-runner.ts refreshes the Harbor session on wake and on `online`
///   (its timer does not count the hours an Apple TV spends asleep);
/// - storage-recovery.ts and the Suwayomi progress bridge flush on hidden;
/// - Trakt/Simkl pending syncs retry on `online`;
/// - mal/auth.ts only signs MAL out after a failed token refresh while `navigator.onLine` is true,
///   so a refresh attempted during a Wi-Fi drop threw the viewer's MAL sign-in away.
/// Started once from `AppModel.boot` after the engine is built.
@MainActor
final class AppLifecycle {
    static let shared = AppLifecycle()

    private var bag = Set<AnyCancellable>()
    private var started = false
    /// Keeps the app running briefly after it leaves the screen so the hidden flush (a sync push
    /// over the network) can finish before tvOS suspends it.
    private var flushTask: UIBackgroundTaskIdentifier = .invalid
    private static let flushSeconds: Double = 8

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.setVisible(false) }
            .store(in: &bag)
        center.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.setVisible(true) }
            .store(in: &bag)
        NetworkStatus.shared.$online
            .removeDuplicates()
            .sink { online in HarborEngine.loaded?.setOnline(online) }
            .store(in: &bag)
        center.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in self?.memoryWarning() }
            .store(in: &bag)
        if UIApplication.shared.applicationState == .background { setVisible(false) }
    }

    /// (perf/memory pass) tvOS warns before it kills an app over its memory limit, and nothing
    /// listened: every cache kept its full budget (posters and backdrops up to 160 MB decoded, the
    /// manga reader's pages up to 160 MB, the kids art, the blurred heroes) and the JS heap waited
    /// for its own next collection. Each cache drops its RAM copy; the disk caches stay, and views
    /// keep the images they are drawing, so nothing on screen changes.
    private func memoryWarning() {
        Task { await ImageLoader.shared.purgeMemory() }
        Task { await MangaPageCache.shared.purgeDecoded() }
        HeroBlur.shared.purge()
        KidsTheme.purgeArt()
        HarborEngine.loaded?.collectGarbage()
    }

    private func setVisible(_ visible: Bool) {
        guard let engine = HarborEngine.loaded else { return }
        endFlush()
        if !visible {
            flushTask = UIApplication.shared.beginBackgroundTask(withName: "harbor.engine-flush") { [weak self] in
                // The expiration handler runs on the main thread and must end the task before it returns.
                MainActor.assumeIsolated { self?.endFlush() }
            }
            let task = flushTask
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.flushSeconds))
                guard let self, self.flushTask == task else { return }
                self.endFlush()
            }
        }
        engine.setVisibility(visible)
    }

    private func endFlush() {
        guard flushTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(flushTask)
        flushTask = .invalid
    }
}
