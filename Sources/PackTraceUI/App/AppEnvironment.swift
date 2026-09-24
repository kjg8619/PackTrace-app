import Foundation
import PackTraceCore
import SwiftUI

/// Single owner of app state. Views read values here and ask for actions; SQLite,
/// the catalogue, the RNG and the OMP log reader never run in a view body.
///
/// Two realms live side by side: the development wallet (`demo`) and the real
/// usage wallet (`production`). Usage rewards are only ever written to
/// production, and the active profile decides which store the collection screens
/// use.
///
/// Uses `ObservableObject` rather than `@Observable`: this machine builds with the
/// Command Line Tools only, where the `SwiftUIMacros` plugin that backs `@State`
/// and `@Observable` is not installed. See docs/TOOLCHAIN.md.
@MainActor
public final class AppEnvironment: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case today
        case vault
        case binder
        case achievements
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .today: "오늘"
            case .vault: "보관함"
            case .binder: "바인더"
            case .achievements: "업적"
            case .settings: "설정"
            }
        }

        var icon: String {
            switch self {
            case .today: "sun.max"
            case .vault: "shippingbox"
            case .binder: "rectangle.stack"
            case .achievements: "trophy"
            case .settings: "gearshape"
            }
        }
    }

    struct OpeningRequest: Identifiable, Hashable {
        var pack: PackInstanceRecord
        var id: PackInstanceID { pack.id }
    }

    public static let shared = AppEnvironment(
        locationRoot: ProcessInfo.processInfo.environment["PACKTRACE_DATA_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        },
        settings: verificationSettings()
    )

    /// Verification runs can point the app at a throwaway preferences suite, so a
    /// GUI check never reads or writes the real one. Without the variable the
    /// normal preferences are used, exactly as before.
    private static func verificationSettings() -> AppSettings {
        guard let suite = ProcessInfo.processInfo.environment["PACKTRACE_SETTINGS_SUITE"] else {
            return AppSettings()
        }
        return AppSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    /// Root directory holding one subdirectory per realm. `nil` means the real
    /// per-realm location under Application Support; tests pass a temporary root.
    private let locationRoot: URL?

    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var catalog: PackCatalog?
    private(set) var library: CatalogLibrary? {
        didSet {
            // Looked up by every shelf tile and candidate row; with every era
            // shipped a scan per lookup adds up.
            var products: [String: PackProduct] = [:]
            for catalog in library?.catalogs.values.sorted(by: { $0.catalogVersion < $1.catalogVersion }) ?? [] {
                for product in catalog.products where products[product.setID] == nil {
                    products[product.setID] = product
                }
            }
            productBySet = products
        }
    }
    private var productBySet: [String: PackProduct] = [:]
    @Published private(set) var store: PackTraceStore?
    @Published private(set) var imageCache: ImageCache?
    /// Which printed pack front belongs to which product, and where those files
    /// live. `nil` means no registry was readable, so every pack falls back to
    /// the substitute wrapper rather than failing to start.
    @Published private(set) var artworkResolver: PackArtworkResolver?
    @Published private(set) var profile: Realm = .demo
    @Published private(set) var isBusy = false

    @Published private(set) var balance = 0
    @Published private(set) var sealedPacks: [PackInstanceRecord] = []
    @Published private(set) var allPacks: [PackInstanceRecord] = []
    @Published private(set) var openings: [OpeningRecord] = []
    @Published private(set) var binderEntries: [BinderEntry] = []
    /// The binder's currently selected set.
    @Published private(set) var progress = BinderProgress(ownedUniquePrints: 0, totalPrints: 0, totalCopies: 0)
    /// Every set together, for the totals on Today and in the menu bar (which
    /// used to show whichever set the binder happened to have selected).
    @Published private(set) var collectionTotals = BinderProgress(ownedUniquePrints: 0, totalPrints: 0, totalCopies: 0)
    /// Set shown in the binder; defaults to the first set the library ships.
    @Published var binderSetID: String = ""
    @Published private(set) var setSummaries: [SetSummary] = []
    /// Binder progress of every set, keyed by set id, for the binder's first
    /// screen (one tile per set).
    @Published private(set) var setProgress: [String: BinderProgress] = [:]
    /// The sets by series, newest first, for the shelves and lists that would
    /// otherwise show every set in one grid.
    @Published private(set) var seriesGroups: [SeriesGroup] = []
    @Published private(set) var ledger: [WalletLedgerEntry] = []
    @Published private(set) var imageStats = ImageCacheStats(memoryEntries: 0, diskEntries: 0, diskBytes: 0, failures: 0)

    @Published private(set) var usage = UsageStatusSnapshot()
    /// Active exchange pool, resolved and validated at bootstrap. `nil` means the
    /// pool could not be used, which is shown as its own state instead of
    /// falling back to fewer candidates.
    @Published private(set) var pool: ResolvedPackPool?
    @Published private(set) var poolError: String?
    /// Pack just received, shown once before it goes to the vault.
    @Published var receivedPack: PackInstanceRecord?
    /// Production wallet balance, always read from the production store so the
    /// usage panel is truthful while the window shows the demo profile.
    @Published private(set) var productionBalance = 0
    /// Achievements of the profile on screen, in catalogue order.
    @Published private(set) var achievements: [AchievementProgress] = []
    @Published private(set) var achievementRecords: [String: AchievementRecord] = [:]
    /// Unlocked since the user last dismissed the notice, from either wallet.
    @Published private(set) var recentUnlocks: [AchievementRecord] = []
    @Published private(set) var achievementError: String?
    /// Accepted tokens when production usage achievements were last judged, so a
    /// usage refresh (several per scan) judges them only when usage changed.
    private var achievementTokensSeen: Int?
    @Published private(set) var usageEvents: [UsageEventRecord] = []
    @Published private(set) var usageCandidates: [OMPLogRootCandidate] = []

    @Published var lastActionError: String?
    @Published private(set) var lastGrantNotice: String?
    /// Result of finishing or rolling back an interrupted restore at launch.
    @Published private(set) var lastRestoreNotice: String?
    /// Development-only: a synthetic opening result shown when
    /// `PACKTRACE_OPENING_PREVIEW=1` is set, so the opening animation can be run
    /// without spending points or writing to a profile.
    @Published var openingPreview: PackOpeningPreview.Result?

    /// Backups available for the active profile, newest first.
    @Published private(set) var backups: [BackupSummary] = []
    @Published var restoreConfirmation: BackupSummary?
    @Published private(set) var isBackingUp = false
    @Published private(set) var isRestoring = false
    @Published private(set) var lastBackupResult: String?
    @Published var selectedTab: Tab = .today
    @Published var openingRequest: OpeningRequest?

    let settings: AppSettings

    private var stores: [Realm: PackTraceStore] = [:]
    private var caches: [Realm: ImageCache] = [:]
    private var collector: OMPUsageCollector?
    /// Reads the tools whose adapters live in Core. OMP keeps its own collector
    /// during this transition; both feed the same reward account.
    @Published private(set) var toolStatuses: [UsageCoordinator.SourceStatus] = []
    @Published private(set) var toolCandidates: [UsageSourceCandidate] = []
    @Published private(set) var toolScanError: String?
    private var coordinator: UsageCoordinator?
    private var scheduler: Task<Void, Never>?
    private var activeMutations = 0
    /// `loadState == .loading` cannot tell "not started" from "already running",
    /// and the app, the window and the menu bar all ask for bootstrap at launch.
    /// Without this flag the second caller reopened the stores and closed the
    /// ones the first caller was still using.
    private var isBootstrapping = false
    /// Held while an exchange is in flight so a double click reuses one request.
    private var pendingExchangeRequestID: ExchangeRequestID?

    /// `locationRoot` replaces the Application Support root; each realm still
    /// gets its own subdirectory underneath it. Tests pass a temporary root so
    /// they can never touch a real collection. `realm` is the starting profile:
    /// `bootstrap()` then honours the profile saved in `settings`.
    public init(realm: Realm = .demo, locationRoot: URL? = nil, settings: AppSettings = AppSettings()) {
        self.settings = settings
        self.profile = realm
        self.locationRoot = locationRoot
    }

    // MARK: - Paths

    /// Catalogue set for the whole app: bundled snapshots plus any snapshot a
    /// restore installed inside either profile.
    private func appLibrary() throws -> CatalogLibrary {
        try CatalogLoader.library(includingLocalDirectories: [
            try location(for: .production).catalogDirectory,
            try location(for: .demo).catalogDirectory,
        ])
    }

    /// Opens (or reopens) the two realm stores. A restore replaces files, so the
    /// environment must be able to rebuild every connection from scratch.
    private func openStores(library: CatalogLibrary) throws {
        var opened: [Realm: PackTraceStore] = [:]
        for realm in [Realm.production, Realm.demo] {
            // A restore that was interrupted is finished or rolled back before
            // anything reads the profile.
            if let notice = try StoreRestore.recoverIfNeeded(location: try location(for: realm)) {
                lastRestoreNotice = notice
            }
            let location = try location(for: realm)
            opened[realm] = try PackTraceStore(location: location, library: library)
            caches[realm] = caches[realm] ?? ImageCache(directory: location.imageDirectory)
        }
        for (realm, previous) in stores {
            if opened[realm] !== previous {
                Task { await previous.close() }
            }
        }
        stores = opened
        collector = OMPUsageCollector(store: opened[.production]!)
        coordinator = UsageCoordinator(
            store: opened[.production]!,
            registry: UsageAdapterRegistry.standard
        )
        store = stores[profile]
        imageCache = caches[profile]
    }

    /// Root holding one directory per realm, plus the pack artwork both share.
    private func rootDirectory() throws -> URL {
        if let locationRoot {
            return locationRoot
        }
        return try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("PackTrace", isDirectory: true)
    }

    private func location(for realm: Realm) throws -> StoreLocation {
        StoreLocation(
            realm: realm,
            directory: try rootDirectory().appendingPathComponent(realm.rawValue, isDirectory: true)
        )
    }

    /// Installed pack artwork sits beside the profiles, not inside one: the same
    /// printed pack is shown in both wallets, and installing it once applies to
    /// both. The fallback path is the same one the installer writes to by default.
    var packArtworkDirectory: URL {
        let base = (try? rootDirectory()) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PackTrace", isDirectory: true)
        return base.appendingPathComponent("pack-artwork", isDirectory: true)
    }

    /// Where a pack's picture is decided. One mapping for the whole app.
    func packArtwork(for product: PackProduct?) -> PackArtworkResolution {
        guard let artworkResolver else { return .substitute(.notRegistered) }
        return artworkResolver.resolve(product: product)
    }

    /// Every catalogue product with the artwork state that will be shown for it.
    /// Presentation status only: it never affects what a pack contains.
    var packArtworkStatuses: [(product: PackProduct, resolution: PackArtworkResolution)] {
        allCatalogs.flatMap(\.products).map { ($0, packArtwork(for: $0)) }
    }

    /// Every loaded catalogue, oldest version first. `catalog` is only the
    /// library's newest one, which left the other sets out of the settings.
    var allCatalogs: [PackCatalog] {
        library?.catalogs.values.sorted { $0.catalogVersion < $1.catalogVersion } ?? []
    }

    var canSwitchProfile: Bool {
        !isBusy && openingRequest == nil && !usage.isScanning
    }

    var isConnectedToUsage: Bool { usage.isConnected }

    // MARK: - Bootstrap

    public func bootstrap() async {
        guard !isBootstrapping else { return }
        guard case .loading = loadState else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }
        do {
            let library = try appLibrary()
            let catalog = library.primary
            self.library = library
            self.catalog = catalog
            caches[.production] = ImageCache(directory: try location(for: .production).imageDirectory)
            caches[.demo] = ImageCache(directory: try location(for: .demo).imageDirectory)
            // Artwork is presentation data: a missing or broken registry only
            // changes what a pack looks like, never what it is.
            artworkResolver = (try? PackArtworkRegistry.loadBundled()).map {
                PackArtworkResolver(registry: $0, directory: packArtworkDirectory)
            }
            try openStores(library: library)
            do {
                let rawPool = try PackPool.loadBundled()
                pool = try ResolvedPackPool.resolve(pool: rawPool, library: library)
                poolError = nil
            } catch {
                // No silent fallback: the exchange screens show that the pool is
                // unusable and leave the wallet untouched.
                pool = nil
                poolError = packTraceMessage(for: error)
            }

            profile = settings.lastProfile
            store = stores[profile]
            imageCache = caches[profile]

            if PackOpeningPreview.isEnabled, openingPreview == nil {
                openingPreview = PackOpeningPreview.makeResult(library: library)
            }

            // Idempotent: pays at most once per demo database, whichever way the
            // demo wallet becomes active.
            await grantDemoPointsIfNeeded()
            await refresh()
            await refreshUsage()
            await refreshToolStatuses()
            loadState = .ready
            startScheduler()
        } catch PackTraceError.catalogNotFound("bundled") {
            loadState = .failed(Self.missingCatalogsMessage)
        } catch {
            loadState = .failed("\(error)")
        }
    }

    /// A build made from a checkout without the card catalogues (they are not
    /// in Git). Says what to run instead of showing a raw error.
    static let missingCatalogsMessage = """
        이 빌드에는 카드 카탈로그가 들어 있지 않습니다. 카탈로그는 Git에 없고 따로 설치합니다.
        저장소 폴더에서 ./scripts/prepare-catalogs.sh <카탈로그 묶음> 을 실행한 뒤 다시 빌드하세요.
        (TCGdex에서 직접 만들려면 ./scripts/prepare-catalogs.sh --rebuild, README의 "Card catalogues" 참고)
        """

    func refresh() async {
        guard let store else { return }
        // Before the balance: an unlock pays its reward into this wallet.
        await evaluateAchievements(store)
        do {
            balance = try await store.balance()
            let packs = try await store.packInstances()
            allPacks = packs
            sealedPacks = packs.filter { $0.state == .sealed }
            openings = try await store.openings()
            setSummaries = store.setSummaries().map {
                SetSummary(
                    setID: $0.set.externalSetID,
                    name: $0.set.name,
                    cards: $0.cards,
                    prints: $0.prints
                )
            }
            if binderSetID.isEmpty { binderSetID = setSummaries.first?.setID ?? "" }
            binderEntries = try await store.binderEntries(setID: binderSetID)
            ledger = try await store.ledger(limit: 60)
            progress = try await store.binderProgress(setID: binderSetID)
            var totals = BinderProgress(ownedUniquePrints: 0, totalPrints: 0, totalCopies: 0)
            let allProgress = try await store.binderProgressBySet()
            var perSet: [String: BinderProgress] = [:]
            for summary in setSummaries {
                let set = allProgress[summary.setID] ?? BinderProgress(ownedUniquePrints: 0, totalPrints: 0, totalCopies: 0)
                perSet[summary.setID] = set
                totals.ownedUniquePrints += set.ownedUniquePrints
                totals.totalPrints += set.totalPrints
                totals.totalCopies += set.totalCopies
            }
            setProgress = perSet
            collectionTotals = totals
            let groups = store.library.seriesGroups(pool: pool)
            if groups != seriesGroups { seriesGroups = groups }
            if let imageCache {
                let stats = await imageCache.stats()
                imageStats = ImageCacheStats(
                    memoryEntries: stats.memoryEntries,
                    diskEntries: stats.diskEntries,
                    diskBytes: stats.diskBytes,
                    failures: stats.failures
                )
            }
        } catch {
            lastActionError = packTraceMessage(for: error)
        }
    }

    // MARK: - Profile

    /// Switches the collection wallet. Blocked while an exchange, opening or
    /// slice is in flight so a purchase can never land in the other database.
    @discardableResult
    func switchProfile(to realm: Realm) async -> Bool {
        guard realm != profile else { return true }
        guard canSwitchProfile else {
            lastActionError = "진행 중인 작업이 끝난 뒤에 지갑 프로필을 바꿀 수 있습니다."
            return false
        }
        guard let target = stores[realm] else { return false }
        profile = realm
        store = target
        imageCache = caches[realm]
        settings.lastProfile = realm
        if realm == .demo {
            await grantDemoPointsIfNeeded()
        }
        lastActionError = nil
        openingRequest = nil
        await refresh()
        refreshBackups()
        return true
    }

    // MARK: - Usage connection

    func refreshUsageCandidates() {
        usageCandidates = OMPLogRootDetector.candidates()
    }

    /// Connects a log root and fixes the baseline. Everything already in the
    /// logs stays unrewarded.
    func connectUsage(root: URL) async {
        guard let collector else { return }
        beginMutation()
        usage.status = .baselining
        usage.isScanning = true
        defer {
            usage.isScanning = false
            endMutation()
        }
        do {
            let source = try await collector.connect(root: root)
            usage.isConnected = true
            usage.rootDisplay = OMPLogRootDetector.displayPath(source.rootPath)
            await runUsageSlices(trigger: .connect)
        } catch {
            lastActionError = packTraceMessage(for: error)
            usage.lastError = packTraceMessage(for: error)
            await refreshUsage()
        }
    }

    func pauseUsage() async {
        guard let collector else { return }
        do {
            try await collector.pause()
            await refreshUsage()
        } catch {
            lastActionError = packTraceMessage(for: error)
        }
    }

    func resumeUsage() async {
        guard let collector else { return }
        beginMutation()
        defer { endMutation() }
        do {
            usage.isScanning = true
            try await collector.resume()
            usage.isScanning = false
            await refreshUsage()
        } catch {
            usage.isScanning = false
            lastActionError = packTraceMessage(for: error)
        }
    }

    /// Manual refresh from the UI.
    func refreshUsageNow() async {
        guard collector != nil else { return }
        guard !usage.requiresReconnect else {
            await refreshUsage()
            return
        }
        guard hasCollectableSource else {
            await refreshUsage()
            return
        }
        beginMutation()
        usage.isScanning = true
        defer {
            usage.isScanning = false
            endMutation()
        }
        await runUsageSlices(trigger: .manual)
    }

    /// Called when the app becomes active again.
    func applicationDidBecomeActive() async {
        guard loadState.isReady, hasCollectableSource, !usage.isScanning else { return }
        usage.isScanning = true
        await runUsageSlices(trigger: .activation)
        usage.isScanning = false
    }

    /// Passes per tick for each collector, so a backlog drains over a few ticks
    /// without holding the app for long.
    static let maxPassesPerTick = 12

    /// Something is connected and not paused: OMP, or any tool with its own
    /// adapter. Scans used to require OMP, so with OMP paused or not connected
    /// the other tools were read only once, when they were connected.
    var hasCollectableSource: Bool {
        (usage.isConnected && !usage.isPaused)
            || toolStatuses.contains { $0.source.tool != .omp && $0.source.status != .unconnected && !$0.source.isPaused }
    }

    private func runUsageSlices(trigger: OMPUsageCollector.Trigger) async {
        // The tools drain their backlog too (a first scan after an upgrade can
        // have thousands of session files to mark), a bounded number of passes.
        for _ in 0..<Self.maxPassesPerTick {
            guard await runToolSlices(trigger: trigger) else { break }
        }
        guard let collector, usage.isConnected, !usage.isPaused else {
            await refreshUsage()
            return
        }
        var slices = 0
        while slices < Self.maxPassesPerTick {
            do {
                let summary = try await collector.scan(trigger: trigger)
                slices += 1
                await refreshUsage()
                if !summary.moreWork { break }
            } catch {
                usage.lastError = packTraceMessage(for: error)
                lastActionError = packTraceMessage(for: error)
                break
            }
        }
        await refreshUsage()
    }

    // MARK: - Tools with their own adapters

    /// One pass over the connected tools. OMP's collector runs alongside this:
    /// both write to the same reward account, so neither is a second wallet.
    @discardableResult
    func runToolSlices(trigger: OMPUsageCollector.Trigger) async -> Bool {
        guard let coordinator else { return false }
        do {
            let summary = try await coordinator.scan(trigger: UsageCoordinator.Trigger(rawValue: trigger.rawValue) ?? .manual)
            toolScanError = summary.errors > 0
                ? "\(summary.errors)개 소스에서 오류가 있었습니다"
                : nil
            // Order matters: the usage snapshot summarises the tool statuses, so
            // those have to be current before it is rebuilt.
            await refreshToolStatuses()
            await refreshUsage()
            return summary.moreWork
        } catch {
            toolScanError = packTraceMessage(for: error)
            await refreshToolStatuses()
            return false
        }
    }

    func refreshToolStatuses() async {
        guard let coordinator else { return }
        toolCandidates = coordinator.candidates()
        do {
            toolStatuses = try await coordinator.status()
        } catch {
            toolScanError = packTraceMessage(for: error)
        }
    }

    /// Connects one tool's storage. The first pass is that tool's baseline, so
    /// nothing already on disk is credited.
    func connectTool(_ tool: UsageToolKind, rootPath: String) async {
        guard let coordinator else { return }
        beginMutation()
        defer { endMutation() }
        do {
            _ = try await coordinator.connect(tool: tool, rootPath: URL(fileURLWithPath: rootPath))
        } catch {
            lastActionError = packTraceMessage(for: error)
        }
        await refreshUsage()
        await refreshToolStatuses()
    }

    func disconnectTool(sourceID: String) async {
        guard let coordinator else { return }
        beginMutation()
        defer { endMutation() }
        do {
            try await coordinator.disconnect(sourceID: sourceID)
        } catch {
            lastActionError = packTraceMessage(for: error)
        }
        await refreshUsage()
        await refreshToolStatuses()
    }

    func setToolPaused(_ paused: Bool, sourceID: String) async {
        guard let coordinator else { return }
        beginMutation()
        defer { endMutation() }
        do {
            if paused {
                try await coordinator.pause(sourceID: sourceID)
            } else {
                try await coordinator.resume(sourceID: sourceID)
            }
        } catch {
            lastActionError = packTraceMessage(for: error)
        }
        await refreshUsage()
        await refreshToolStatuses()
    }

    /// Collection across OMP and every other tool. The Today panel, the menu
    /// bar and the top of Settings read this; `usage` alone is only OMP's
    /// connection plus the shared account.
    var usageOverview: UsageOverview {
        UsageOverview.make(omp: usage, tools: toolStatuses)
    }

    /// Stops reading every connected source: OMP through its collector, the
    /// other tools through the coordinator. One source at a time is paused in
    /// Settings.
    func pauseAllUsage() async {
        beginMutation()
        defer { endMutation() }
        var failure: Error?
        if let collector, usage.isConnected, !usage.isPaused {
            do { try await collector.pause() } catch { failure = failure ?? error }
        }
        if let coordinator {
            for status in toolStatuses where status.source.tool != .omp
                && status.source.status != .unconnected && !status.source.isPaused {
                do { try await coordinator.pause(sourceID: status.source.sourceID) } catch { failure = failure ?? error }
            }
        }
        if let failure { lastActionError = packTraceMessage(for: failure) }
        await refreshToolStatuses()
        await refreshUsage()
    }

    /// Resumes every paused source. Each resume reads what accumulated while it
    /// was paused.
    func resumeAllUsage() async {
        beginMutation()
        usage.isScanning = true
        defer {
            usage.isScanning = false
            endMutation()
        }
        var failure: Error?
        if let collector, usage.isConnected, usage.isPaused {
            do { try await collector.resume() } catch { failure = failure ?? error }
        }
        if let coordinator {
            for status in toolStatuses where status.source.tool != .omp
                && status.source.status != .unconnected && status.source.isPaused {
                do { try await coordinator.resume(sourceID: status.source.sourceID) } catch { failure = failure ?? error }
            }
        }
        if let failure { lastActionError = packTraceMessage(for: failure) }
        await refreshToolStatuses()
        await refreshUsage()
    }

    func refreshUsage() async {
        guard let collector, let production = stores[.production] else { return }
        do {
            let status = try await collector.status()
            var snapshot = UsageStatusSnapshot()
            snapshot.isConnected = status.source != nil && status.source?.status != .unconnected
            snapshot.status = status.source?.status ?? .unconnected
            snapshot.isPaused = status.source?.isPaused ?? false
            snapshot.requiresReconnect = !snapshot.isConnected
                && status.latestSource?.lastReason == OMPUsageCollector.restoreReconnectReason
            snapshot.rootPath = (status.source ?? status.latestSource)?.rootPath
            snapshot.rootDisplay = snapshot.rootPath.map { OMPLogRootDetector.displayPath($0) } ?? "-"
            snapshot.baselineFilesTotal = status.baselineFilesTotal
            snapshot.baselineFilesDone = status.baselineFilesDone
            snapshot.baselineComplete = status.isBaselineComplete
            // The newest scan run can belong to any tool, so it stands in for
            // OMP's own time only while OMP is connected.
            snapshot.lastScanAt = status.source.flatMap { $0.lastScanAt ?? status.lastRun?.finishedAt }
            snapshot.pendingWork = status.pendingWork
            snapshot.lastError = status.source?.lastReason

            if achievementTokensSeen != status.totals.acceptedTokens {
                achievementTokensSeen = status.totals.acceptedTokens
                await evaluateAchievements(production)
            }
            productionBalance = try await production.balance()
            // The wallet on screen is the production one: its balance moved too.
            if store === production {
                balance = productionBalance
            }
            let today = try await production.usageDayTotals(day: Date(), calendar: UsageCalendar.seoul)
            snapshot.todayAcceptedTokens = today.acceptedTokens
            snapshot.todayAcceptedEvents = today.acceptedEvents
            snapshot.todayAwardedPoints = today.awardedPoints
            snapshot.todayByTool = (try? await production.usageDayByTool(day: Date(), calendar: UsageCalendar.seoul)) ?? []

            snapshot.totalAcceptedTokens = status.totals.acceptedTokens
            snapshot.remainderTokens = status.totals.remainderTokens
            snapshot.awardedPoints = status.totals.awardedPoints
            snapshot.acceptedEvents = status.totals.acceptedEvents
            snapshot.baselineEvents = status.diagnostics.baselineEvents
            snapshot.duplicateEvents = status.diagnostics.duplicateEvents
            snapshot.excludedEvents = status.diagnostics.excludedEvents
            snapshot.unsupportedEvents = status.diagnostics.unsupportedEvents
            snapshot.conflictEvents = status.diagnostics.conflictEvents
            snapshot.aliasEvents = status.diagnostics.aliasEvents
            snapshot.sessionsObserved = status.diagnostics.sessionsObserved
            snapshot.sessionsWithParent = status.diagnostics.sessionsWithParent
            snapshot.filesTracked = status.diagnostics.filesTracked
            snapshot.filesWithErrors = status.diagnostics.filesWithErrors
            snapshot.rejectReasons = status.diagnostics.excludedByIdentity
            snapshot.toolTotals = (try? await production.usageToolTotals(ruleID: collector.rule.ruleID)) ?? []
            snapshot.ruleID = status.totals.ruleID
            snapshot.tokensPerPoint = collector.rule.tokensPerPoint
            snapshot.packCostPoints = production.economy.packCostPoints
            // A refresh happens in the middle of a scan: the snapshot is rebuilt
            // from storage, but whether a scan is running is not stored there.
            // Dropped, the refresh buttons came back and the restore guard let a
            // restore close the stores under a running scan.
            snapshot.isScanning = usage.isScanning
            usage = snapshot
            usageEvents = try await production.usageRecentEvents(limit: 12)
            if usageCandidates.isEmpty {
                // Listing the log directories is only needed until there is
                // something to show; the settings screen refreshes it on demand.
                refreshUsageCandidates()
            }
        } catch {
            usage.lastError = packTraceMessage(for: error)
        }
    }

    // MARK: - Achievements

    /// Judges `target`'s achievements and pays new rewards. Progress is shown
    /// for the profile on screen; unlocks from either wallet are announced.
    private func evaluateAchievements(_ target: PackTraceStore) async {
        do {
            let evaluation = try await target.evaluateAchievements()
            if target === store {
                achievements = evaluation.progress
                achievementRecords = evaluation.records
            }
            recentUnlocks.append(contentsOf: evaluation.newlyUnlocked)
            achievementError = nil
        } catch {
            achievementError = packTraceMessage(for: error)
        }
    }

    func dismissRecentUnlocks() {
        recentUnlocks = []
    }

    // MARK: - Scheduler

    private func startScheduler() {
        scheduler?.cancel()
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                await self.scheduledUsageScan()
            }
        }
    }

    /// One scheduled tick: collects whatever accumulated while idle and keeps
    /// draining slices until the backlog is gone.
    func scheduledUsageScan() async {
        guard loadState.isReady, hasCollectableSource, !usage.isScanning else { return }
        usage.isScanning = true
        await runUsageSlices(trigger: .scheduled)
        usage.isScanning = false
    }

    /// Development grant: demo realm only, at most once per database (the store
    /// refuses it elsewhere).
    private func grantDemoPointsIfNeeded() async {
        guard let demo = stores[.demo] else { return }
        if let granted = try? await demo.grantInitialDemoPoints() {
            lastGrantNotice = "개발용 포인트 \(granted) P를 최초 1회 지급했습니다."
        }
        if profile == .demo {
            await refresh()
        }
    }

    private func beginMutation() {
        activeMutations += 1
        isBusy = true
    }

    private func endMutation() {
        activeMutations = max(0, activeMutations - 1)
        isBusy = activeMutations > 0
    }

    // MARK: - Catalogue helpers

    var unfinishedOpenings: [OpeningRecord] {
        openings.filter { !$0.isComplete }
    }

    var candidateSummary: [(product: PackProduct, probability: Double, catalogVersion: String, recipeVersion: Int)] {
        guard let store, let pool else { return [] }
        return store.candidateSummary(pool: pool)
    }

    var packCostPoints: Int { pool?.pricePoints ?? store?.economy.packCostPoints ?? PackEconomy.v1.packCostPoints }

    // MARK: - Actions

    @discardableResult
    func exchangeRandomPack() async -> PackInstanceRecord? {
        guard let store, let pool else {
            lastActionError = poolError ?? "팩 후보 목록이 준비되지 않았습니다."
            return nil
        }
        beginMutation()
        defer { endMutation() }
        do {
            // One explicit user action = one request id. A retry of the same
            // action reuses it, so a double click cannot create two purchases.
            let requestID = pendingExchangeRequestID ?? ExchangeRequestID()
            pendingExchangeRequestID = requestID
            let outcome = try await store.exchangePack(
                pool: pool,
                requestID: requestID,
                // Production randomness; tests inject a deterministic seed.
                seed: settings.testSeed ?? SeedSource.randomSeed()
            )
            pendingExchangeRequestID = nil
            lastActionError = nil
            await refresh()
            receivedPack = outcome.packInstance
            return outcome.packInstance
        } catch {
            pendingExchangeRequestID = nil
            lastActionError = packTraceMessage(for: error)
            return nil
        }
    }

    func openPack(_ instanceID: PackInstanceID) async throws -> OpeningRecord {
        guard let store else { throw PackTraceError.storage("저장소가 준비되지 않았습니다") }
        // Production draws from the system generator; tests inject a seed so a
        // run can be compared with another run of the same pack.
        let opening = try await store.openPack(
            instanceID: instanceID,
            seed: settings.testSeed ?? SeedSource.randomSeed()
        )
        await refresh()
        return opening
    }

    func revealNext(_ opening: OpeningRecord) async -> OpeningRecord? {
        guard let store else { return nil }
        guard !opening.isComplete else { return opening }
        do {
            let updated = try await store.setRevealedCount(openingID: opening.id, count: opening.revealedCount + 1)
            openings = try await store.openings()
            return updated
        } catch {
            lastActionError = packTraceMessage(for: error)
            return nil
        }
    }

    func revealAll(_ opening: OpeningRecord) async -> OpeningRecord? {
        guard let store else { return nil }
        do {
            let updated = try await store.setRevealedCount(openingID: opening.id, count: opening.cards.count)
            await refresh()
            return updated
        } catch {
            lastActionError = packTraceMessage(for: error)
            return nil
        }
    }

    func opening(for pack: PackInstanceRecord) -> OpeningRecord? {
        openings.first { $0.packInstanceID == pack.id }
    }

    /// Opens the tear flow for a sealed pack, or resumes the reveal for an
    /// already-opened one. The pack itself is never re-drawn here.
    func requestOpening(pack: PackInstanceRecord) {
        selectedTab = .vault
        openingRequest = OpeningRequest(pack: pack)
    }

    func requestOpening(packID: PackInstanceID) {
        guard let pack = allPacks.first(where: { $0.id == packID }) else { return }
        requestOpening(pack: pack)
    }

    func product(for pack: PackInstanceRecord) -> PackProduct? {
        library?.product(id: pack.productID)
    }

    func setInfo(for setID: String) -> CardSetInfo? {
        library?.setInfo(for: setID)
    }

    /// Cards of every set matching the query, as binder rows (see
    /// `PackTraceStore.searchBinder`). Empty when there is no store.
    func searchCards(_ query: String, limit: Int = 300) async -> (entries: [BinderEntry], total: Int) {
        guard let store else { return ([], 0) }
        return (try? await store.searchBinder(query: query, limit: limit)) ?? ([], 0)
    }

    /// Game cards in one pack of this product (2 for POP, 11 for Wizards-era
    /// sets …), from the newest snapshot that carries it.
    func packSize(of product: PackProduct?) -> Int? {
        guard let product, let library else { return nil }
        return library.catalogs.values
            .sorted { $0.catalogVersion > $1.catalogVersion }
            .lazy
            .compactMap { $0.products.contains { $0.packID == product.packID } ? $0.recipe(id: product.recipeID)?.packSize : nil }
            .first
    }

    /// The pack product whose cards come from this set, for showing a set as
    /// its pack. The first one when a set has more than one.
    func product(forSet setID: String) -> PackProduct? {
        // A subset (Trainer Gallery …) has no pack of its own: it came in its
        // parent set's packs.
        productBySet[setID] ?? library?.parentSetID(of: setID).flatMap { productBySet[$0] }
    }

    /// When each copy of a print was obtained, for the card detail. Nil when it
    /// could not be read, so the view can say so instead of showing "none".
    func acquisitionDates(of card: CardKey, variant: CardVariant) async -> [Date]? {
        guard let store else { return nil }
        return try? await store.acquisitionDates(cardKey: card, variant: variant)
    }

    /// Binder rows for another set, used by the set picker.
    func selectBinderSet(_ setID: String) async {
        binderSetID = setID
        guard let store else { return }
        binderEntries = (try? await store.binderEntries(setID: setID)) ?? []
        progress = (try? await store.binderProgress(setID: setID))
            ?? BinderProgress(ownedUniquePrints: 0, totalPrints: 0, totalCopies: 0)
    }

    func card(for key: CardKey) -> CardDefinition? {
        library?.card(for: key)
    }

    /// Set of a product, for labels.
    func setID(for product: PackProduct?) -> String {
        product?.setID ?? ""
    }

    func firstTimePrintKeys(openingID: OpeningID) async -> Set<String> {
        guard let store else { return [] }
        return (try? await store.firstTimePrints(openingID: openingID)) ?? []
    }

    func clearImageCache() async {
        await imageCache?.clearDisk()
        await refresh()
    }

    func imageData(for urlString: String, quality: CardImageQuality) async -> Data? {
        await imageCache?.data(for: urlString, quality: quality)
    }

    // MARK: - Backup and restore

    struct BackupSummary: Identifiable, Equatable {
        var url: URL
        var manifest: BackupManifest
        var id: String { url.lastPathComponent }

        var displayName: String {
            let stamp = url.lastPathComponent
                .replacingOccurrences(of: ".\(BackupManifest.packageExtension)", with: "")
            return stamp
        }

        var createdAtLabel: String {
            manifest.createdAtDate?.packTraceDisplay ?? manifest.createdAt
        }

        var detailLine: String {
            let counts = manifest.counts
            return "잔액 \(counts.balancePoints) P · 미개봉 \(counts.sealedPacks) · 개봉 \(counts.openedPacks) · 카드 \(counts.ownedCards)"
        }
    }

    func refreshBackups() {
        do {
            let location = try location(for: profile)
            backups = StoreBackup.list(location: location).compactMap { url in
                guard let manifest = try? StoreBackup.loadManifest(packageURL: url) else { return nil }
                return BackupSummary(url: url, manifest: manifest)
            }
        } catch {
            backups = []
            lastActionError = packTraceMessage(for: error)
        }
    }

    /// Creates a backup of the active profile. Images are not included: only the
    /// database, the manifests and the catalogue snapshots the packs need.
    func createBackup() async {
        guard let library, !isBackingUp, !isRestoring else { return }
        isBackingUp = true
        defer { isBackingUp = false }
        do {
            let location = try location(for: profile)
            let outcome = try await Task.detached(priority: .userInitiated) {
                try StoreBackup.create(
                    location: location,
                    library: library,
                    poolVersion: try? PackPool.loadBundled().poolVersion
                )
            }.value
            lastBackupResult = "\(outcome.packageURL.lastPathComponent) 생성 · \(ByteCountFormatter.string(fromByteCount: Int64(outcome.manifest.databaseBytes), countStyle: .file))"
            lastActionError = nil
            refreshBackups()
        } catch {
            lastActionError = packTraceMessage(for: error)
        }
    }

    /// Replaces the active profile with a backup. The collector stops first; the
    /// restored profile then requires an explicit reconnect before it can reward
    /// anything again.
    func restore(from summary: BackupSummary) async {
        guard let library, !isBusy, !isRestoring, !usage.isScanning else { return }
        isRestoring = true
        beginMutation()
        defer {
            isRestoring = false
            endMutation()
        }
        let realm = profile
        do {
            // Only a production restore replaces the database the collector
            // writes to. Pausing it for a demo restore stopped real collection
            // until someone noticed and resumed it.
            if realm == .production, let collector {
                try? await collector.pause()
            }
            let location = try location(for: realm)
            let current = stores[realm]
            if let current {
                stores.removeValue(forKey: realm)
                await current.close()
            }
            let plan = try await Task.detached(priority: .userInitiated) {
                try StoreRestore.restore(packageURL: summary.url, location: location, library: library)
            }.value
            let libraryAfter = try appLibrary()
            self.library = libraryAfter
            catalog = libraryAfter.primary
            try openStores(library: libraryAfter)
            if let rawPool = try? PackPool.loadBundled() {
                pool = try? ResolvedPackPool.resolve(pool: rawPool, library: libraryAfter)
            }
            openingRequest = nil
            receivedPack = nil
            await grantDemoPointsIfNeeded()
            await refresh()
            await refreshUsage()
            refreshBackups()
            lastBackupResult = "복원 완료 · 잔액 \(plan.manifest.counts.balancePoints) P · 미개봉 \(plan.manifest.counts.sealedPacks)"
            lastActionError = nil
        } catch {
            // Nothing was replaced when validation failed; reopen what we had.
            try? openStores(library: try appLibrary())
            await refresh()
            await refreshUsage()
            lastActionError = packTraceMessage(for: error)
        }
    }

    func deleteBackup(_ summary: BackupSummary) {
        do {
            try StoreBackup.delete(packageURL: summary.url, location: try location(for: profile))
            refreshBackups()
        } catch {
            lastActionError = packTraceMessage(for: error)
        }
    }

    // MARK: - Testing seam

    #if DEBUG
    func activeStore(for realm: Realm) -> PackTraceStore? { stores[realm] }
    #endif
}

/// Human-readable message for an error raised by the core layer. `LocalizedError`
/// covers every `PackTraceError`; anything else falls back to its description.
func packTraceMessage(for error: any Error) -> String {
    if let localized = error as? any LocalizedError, let description = localized.errorDescription {
        return description
    }
    return String(describing: error)
}

/// Snapshot of cache counters, kept `Sendable`-friendly for the UI layer.
struct ImageCacheStats: Equatable {
    var memoryEntries: Int
    var diskEntries: Int
    var diskBytes: Int
    var failures: Int
}

/// Opening options and the last used profile. Stored in UserDefaults; the
/// opening switches change presentation only, never the stored result of a pack.
@MainActor
public final class AppSettings: ObservableObject {
    private enum Key {
        static let fastOpen = "packtrace.settings.fastOpen"
        static let reduceMotion = "packtrace.settings.reduceMotion"
        static let sound = "packtrace.settings.sound"
        static let profile = "packtrace.settings.profile"
        static let vaultLayout = "packtrace.settings.vaultLayout"
    }

    private let defaults: UserDefaults

    @Published var fastOpen: Bool { didSet { defaults.set(fastOpen, forKey: Key.fastOpen) } }
    @Published var reduceMotion: Bool { didSet { defaults.set(reduceMotion, forKey: Key.reduceMotion) } }
    @Published var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: Key.sound) } }
    /// Deterministic seed for tests. `nil` in normal runs, so production always
    /// draws from the system generator.
    var testSeed: UInt64?

    @Published var lastProfile: Realm {
        didSet { defaults.set(lastProfile.rawValue, forKey: Key.profile) }
    }

    /// How the vault shows packs. Remembered between launches; packs first
    /// unless the user picked the list.
    @Published var vaultLayout: VaultLayout {
        didSet { defaults.set(vaultLayout.rawValue, forKey: Key.vaultLayout) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.fastOpen = defaults.bool(forKey: Key.fastOpen)
        self.reduceMotion = defaults.bool(forKey: Key.reduceMotion)
        self.soundEnabled = defaults.object(forKey: Key.sound) as? Bool ?? true
        self.lastProfile = Realm(rawValue: defaults.string(forKey: Key.profile) ?? "") ?? .demo
        self.vaultLayout = VaultLayout(rawValue: defaults.string(forKey: Key.vaultLayout) ?? "") ?? .gallery
    }

    /// True when the tear animation should be skipped for this opening.
    func skipsAnimations(systemReduceMotion: Bool) -> Bool {
        fastOpen || reduceMotion || systemReduceMotion
    }
}
