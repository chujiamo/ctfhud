import AppKit
import SwiftUI
import UserNotifications

private let windowPreferencesKey = "org.ctfhud.local.windowPreferences.v4"
private let previousWindowPreferencesKey = "org.ctfhud.local.windowPreferences.v3"
private let languagePreferencesKey = "org.ctfhud.local.languagePreference.v1"
private let legacyWindowPreferencesKey = "org.ctfhud.local.windowPreferences.v2"

struct WindowOrigin: Codable {
    var x: Double
    var y: Double
}

private struct WindowPreferences: Codable {
    var clickThrough = false
    var positionLocked = false
    var cleanMode = false
    var backgroundOpacity = 0.97
    var textOpacity = 1.0
    var origin: WindowOrigin? = nil
    var visibility = HUDVisibility()
}

// v1.3 saved these window fields without per-item visibility controls.
private struct PreviousWindowPreferences: Codable {
    var clickThrough = false
    var positionLocked = false
    var cleanMode = false
    var backgroundOpacity = 0.97
    var textOpacity = 1.0
    var origin: WindowOrigin? = nil
}

// One-time migration for settings saved by v1.2. The old slider dimmed
// the entire panel; apply it to both channels to preserve its appearance.
private struct LegacyWindowPreferences: Codable {
    var clickThrough = false
    var positionLocked = false
    var opacity = 1.0
    var origin: WindowOrigin? = nil
}

private let accent = Color(red: 1.0, green: 0.48, blue: 0.78)
private let muted = Color(red: 0.66, green: 0.67, blue: 0.76)

final class HUDStore: ObservableObject {
    @Published var config: AppConfig { didSet { save() } }
    @Published var now = Date()
    @Published var snapshot = ScoreSnapshot(rank: nil, categoryRank: nil, score: nil, submissions: [], status: "排行榜未接入")
    @Published var clickThrough = false {
        didSet { saveWindowPreferences(); onWindowStateChanged?() }
    }
    @Published var positionLocked = false {
        didSet { saveWindowPreferences(); onWindowStateChanged?() }
    }
    @Published var cleanMode = false {
        didSet { saveWindowPreferences(); onWindowStateChanged?() }
    }
    @Published var backgroundOpacity = 0.97 {
        didSet { saveWindowPreferences(); onWindowStateChanged?() }
    }
    @Published var textOpacity = 1.0 {
        didSet { saveWindowPreferences(); onWindowStateChanged?() }
    }
    @Published var visibility = HUDVisibility() {
        didSet { saveWindowPreferences(); onWindowStateChanged?() }
    }
    @Published var isAdjustingPosition = false {
        didSet { onWindowStateChanged?() }
    }
    @Published var windowOrigin: WindowOrigin? = nil {
        didSet { saveWindowPreferences() }
    }
    @Published var isVisible = true
    @Published var languageChoice = "system" {
        didSet {
            UserDefaults.standard.set(HUDLanguage.canonical(languageChoice), forKey: languagePreferencesKey)
            onLanguageChanged?()
        }
    }
    var onLanguageChanged: (() -> Void)?
    var onWindowStateChanged: (() -> Void)?
    var onResetWindowPosition: (() -> Void)?

    var effectiveClickThrough: Bool { clickThrough && !isAdjustingPosition }
    var effectivePositionLocked: Bool { positionLocked && !isAdjustingPosition }
    // Never show stale data in clean mode: only a successful sync qualifies.
    var hasLiveScoreboard: Bool {
        FeedProtocol.canonical(active.feedMode) != FeedProtocol.off && snapshot.status == "已同步" &&
        lastSuccessfulUpdate != nil && lastSyncedFeedSignature == feedSignature(active)
    }

    @Published var scoreChanges: ScoreChanges? = nil
    @Published var lastComparedUpdate: Date? = nil
    private var lastValidSnapshot: ScoreSnapshot?
    private var lastSyncedFeedSignature: String?

    private func feedSignature(_ p: ContestProfile) -> String {
        [p.id.uuidString, p.teamName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
         p.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
         FeedProtocol.canonical(p.feedMode), p.feedURL.trimmingCharacters(in: .whitespacesAndNewlines)].joined(separator: "|")
    }
    var cleanLog: [SubmissionEntry] {
        let remote = hasLiveScoreboard ? snapshot.submissions : []
        return (active.manualSubmissions + remote).sorted { $0.time > $1.time }
    }

    func startPositionAdjustment() {
        isAdjustingPosition = true
    }

    func finishPositionAdjustment() {
        isAdjustingPosition = false
    }

    private func saveWindowPreferences() {
        let preferences = WindowPreferences(clickThrough: clickThrough,
                                            positionLocked: positionLocked,
                                            cleanMode: cleanMode,
                                            backgroundOpacity: backgroundOpacity,
                                            textOpacity: textOpacity,
                                            origin: windowOrigin,
                                            visibility: visibility)
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: windowPreferencesKey)
        }
    }
    @Published var lastSuccessfulUpdate: Date?
    private var previousTick: Date?
    private var fired: Set<String> = []
    private var fetching = false
    private var requestedProfile: UUID?
    private var lastFetch: Date = .distantPast

    static let configURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("CTFHUD", isDirectory: true).appendingPathComponent("config.json")
    }()

    init() {
        languageChoice = HUDLanguage.canonical(UserDefaults.standard.string(forKey: languagePreferencesKey) ?? "system")
        if let bytes = try? Data(contentsOf: Self.configURL),
           let saved = try? JSONDecoder().decode(AppConfig.self, from: bytes),
           !saved.profiles.isEmpty {
            config = saved
        } else {
            config = ClockCore.initialConfig()
        }
        // Migrate v1.5 identifiers (hkcert / ctfd / json) without changing
        // local team names, milestones, submissions or custom endpoint URLs.
        for index in config.profiles.indices {
            config.profiles[index].feedMode = FeedProtocol.canonical(config.profiles[index].feedMode)
        }
        if !config.profiles.contains(where: { $0.id == config.activeID }) {
            config.activeID = config.profiles[0].id
        }
        if let data = UserDefaults.standard.data(forKey: windowPreferencesKey),
           let preferences = try? JSONDecoder().decode(WindowPreferences.self, from: data) {
            clickThrough = preferences.clickThrough
            positionLocked = preferences.positionLocked
            cleanMode = preferences.cleanMode
            backgroundOpacity = min(1.0, max(0.0, preferences.backgroundOpacity))
            textOpacity = min(1.0, max(0.10, preferences.textOpacity))
            windowOrigin = preferences.origin
            visibility = preferences.visibility
        } else if let data = UserDefaults.standard.data(forKey: previousWindowPreferencesKey),
                  let previous = try? JSONDecoder().decode(PreviousWindowPreferences.self, from: data) {
            clickThrough = previous.clickThrough
            positionLocked = previous.positionLocked
            cleanMode = previous.cleanMode
            backgroundOpacity = min(1.0, max(0, previous.backgroundOpacity))
            textOpacity = min(1.0, max(0.10, previous.textOpacity))
            windowOrigin = previous.origin
            saveWindowPreferences()
        } else if let data = UserDefaults.standard.data(forKey: legacyWindowPreferencesKey),
                  let legacy = try? JSONDecoder().decode(LegacyWindowPreferences.self, from: data) {
            clickThrough = legacy.clickThrough
            positionLocked = legacy.positionLocked
            backgroundOpacity = min(1.0, max(0, legacy.opacity * 0.97))
            textOpacity = min(1.0, max(0.10, legacy.opacity))
            windowOrigin = legacy.origin
            saveWindowPreferences()
        }
    }

    var active: ContestProfile {
        get { config.profiles.first(where: { $0.id == config.activeID }) ?? config.profiles[0] }
        set {
            if let index = config.profiles.firstIndex(where: { $0.id == config.activeID }) {
                config.profiles[index] = newValue
            }
        }
    }

    func edit(_ change: (inout ContestProfile) -> Void) {
        let before = feedSignature(active)
        var p = active
        change(&p)
        active = p
        if feedSignature(p) != before {
            // A different team, category or endpoint must never inherit scores
            // or deltas from the previous scoreboard source.
            snapshot = ScoreSnapshot(rank: nil, categoryRank: nil, score: nil,
                                     submissions: [], status: "排行榜配置已更改，请刷新")
            lastValidSnapshot = nil
            lastSyncedFeedSignature = nil
            scoreChanges = nil
            lastComparedUpdate = nil
            lastSuccessfulUpdate = nil
            lastFetch = .distantPast
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.configURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(config)
            try data.write(to: Self.configURL, options: .atomic)
        } catch { NSLog("CTFHUD: could not save preferences: %@", error.localizedDescription) }
    }

    func addProfile() {
        var p = ClockCore.newProfile()
        p.name = L10n.tr("新比赛（请设置）", choice: languageChoice)
        for i in p.milestones.indices {
            p.milestones[i].title = L10n.tr(p.milestones[i].title, choice: languageChoice)
        }
        config.profiles.append(p)
        switchProfile(to: p.id)
    }

    func deleteProfile() {
        guard config.profiles.count > 1 else { return }
        config.profiles.removeAll(where: { $0.id == config.activeID })
        switchProfile(to: config.profiles[0].id)
    }

    func switchProfile(to id: UUID) {
        guard config.profiles.contains(where: { $0.id == id }) else { return }
        config.activeID = id
        snapshot = ScoreSnapshot(rank: nil, categoryRank: nil, score: nil, submissions: [], status: "排行榜未接入")
        lastSuccessfulUpdate = nil
        lastValidSnapshot = nil
        lastSyncedFeedSignature = nil
        scoreChanges = nil
        lastComparedUpdate = nil
        lastFetch = .distantPast
        previousTick = Date()
        fetchScores(force: true)
    }

    func addMilestone() {
        edit { p in
            let soon = p.milestones.filter { $0.date > Date() }.map(\.date).sorted().first
                ?? Date().addingTimeInterval(3600)
            p.milestones.append(Milestone(title: L10n.tr("新阶段", choice: languageChoice), date: soon, kind: "phase"))
        }
    }

    func updateMilestone(_ milestone: Milestone) {
        edit { p in
            if let index = p.milestones.firstIndex(where: { $0.id == milestone.id }) {
                p.milestones[index] = milestone
            }
        }
    }

    func removeMilestone(id: UUID) {
        edit { p in
            if let milestone = p.milestones.first(where: { $0.id == id }), milestone.kind == "phase" {
                p.milestones.removeAll(where: { $0.id == id })
            }
        }
    }

    var upcoming: Milestone? { active.milestones.filter { $0.date > now }.min(by: { $0.date < $1.date }) }
    var end: Milestone? { active.milestones.filter { $0.kind == "end" }.max(by: { $0.date < $1.date }) }
    var log: [SubmissionEntry] {
        (active.manualSubmissions + snapshot.submissions).sorted { $0.time > $1.time }
    }

    func tick() {
        let current = Date()
        let p = active
        if p.soundEnabled {
            let alerts = ClockCore.dueAlerts(profile: p, previous: previousTick, now: current, fired: fired)
            for alert in alerts {
                fired.insert(alert.key)
                soundAlert(title: alert.stage.title, minutes: alert.minutes)
            }
        }
        previousTick = current
        now = current
        if current.timeIntervalSince(lastFetch) >= 120 { fetchScores(force: false) }
    }

    func soundAlert(title: String, minutes: Int) {
        NSSound(named: NSSound.Name("Glass"))?.play()
        let count = minutes >= 60 ? String(minutes / 60) : String(minutes)
        let unit = minutes >= 60 ? L10n.tr("小时", choice: languageChoice) : L10n.tr("分钟", choice: languageChoice)
        let notification = UNMutableNotificationContent()
        notification.title = "CTF HUD · \(L10n.tr(title, choice: languageChoice))"
        notification.body = L10n.format("距离该节点还有 {{count}} {{unit}}", choice: languageChoice,
                                        values: ["count": count, "unit": unit])
        // Audio is played directly; avoid a second notification sound.
        notification.sound = nil
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: notification, trigger: nil))
    }

    func fetchScores(force: Bool) {
        let p = active
        guard FeedProtocol.canonical(p.feedMode) != FeedProtocol.off else {
            snapshot.status = "排行榜未接入（可在设置中启用）"
            lastSyncedFeedSignature = nil
            scoreChanges = nil
            return
        }
        guard !fetching else { return }
        if !force && Date().timeIntervalSince(lastFetch) < 120 { return }
        lastFetch = Date()
        guard FeedProtocol.isValidEndpoint(p.feedURL),
              let url = URL(string: p.feedURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            snapshot.status = "请输入有效端点（远程须 HTTPS；本机可使用 HTTP）"
            return
        }
        fetching = true
        requestedProfile = p.id
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: cfg)
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("CTFHUD/1.8.1", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.fetching = false
                defer { session.finishTasksAndInvalidate() }
                guard self.config.activeID == p.id,
                      self.feedSignature(self.active) == self.feedSignature(p) else { return }
                if let error = error {
                    self.snapshot.status = "同步失败：\(error.localizedDescription)（原数据可能过时）"
                    return
                }
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                      let data = data, data.count < 8_000_000 else {
                    self.snapshot.status = "无法读取排行榜（HTTP 状态异常或内容过大）"
                    return
                }
                do {
                    let parsed = try ClockCore.parseScoreboard(data, mode: p.feedMode,
                                                               teamName: p.teamName, category: p.category)
                    let signature = self.feedSignature(p)
                    if parsed.status == "已同步" &&
                       (parsed.rank != nil || parsed.categoryRank != nil || parsed.score != nil) {
                        if let last = self.lastValidSnapshot,
                           self.lastSyncedFeedSignature == signature,
                           let previousTime = self.lastSuccessfulUpdate {
                            self.scoreChanges = ScoreChanges.between(last, parsed)
                            self.lastComparedUpdate = previousTime
                        } else {
                            self.scoreChanges = nil  // first usable sample is a baseline
                            self.lastComparedUpdate = nil
                        }
                        self.lastValidSnapshot = parsed
                        self.lastSyncedFeedSignature = signature
                        self.lastSuccessfulUpdate = Date()
                    } else {
                        self.scoreChanges = nil
                        self.lastComparedUpdate = nil
                        self.lastValidSnapshot = nil
                        self.lastSyncedFeedSignature = nil
                        self.lastSuccessfulUpdate = nil
                    }
                    self.snapshot = parsed
                } catch {
                    self.snapshot.status = "数据格式不匹配：\(error.localizedDescription)"
                }
            }
        }.resume()
    }

    func openOfficialScoreboard() {
        guard let url = URL(string: active.scoreboardURL), url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct HUDValue: View {
    let label: String
    let value: String
    let detail: String
    let color: Color
    let textOpacity: Double
    let showLabel: Bool
    let showValue: Bool
    let showDetail: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showLabel {
                Text(label).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(muted.opacity(textOpacity)).lineLimit(1)
            }
            if showValue {
                Text(value).font(.system(size: 27, weight: .bold, design: .monospaced))
                    .foregroundStyle(color.opacity(textOpacity)).lineLimit(1).minimumScaleFactor(0.6)
            }
            if showDetail {
                Text(detail).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(muted.opacity(textOpacity)).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Header-only dragging is reliable even when the rest of the HUD contains SwiftUI views.
private final class HUDNativeDragView: NSView {
    var dragEnabled = true

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        guard dragEnabled else { return }
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if dragEnabled { addCursorRect(bounds, cursor: .openHand) }
    }
}

private struct HUDDragSurface: NSViewRepresentable {
    var enabled: Bool

    func makeNSView(context: Context) -> HUDNativeDragView {
        let view = HUDNativeDragView(frame: .zero)
        view.dragEnabled = enabled
        return view
    }

    func updateNSView(_ view: HUDNativeDragView, context: Context) {
        view.dragEnabled = enabled
        view.window?.invalidateCursorRects(for: view)
    }
}

struct HUDView: View {
    @ObservedObject var store: HUDStore

    private func t(_ key: String) -> String { L10n.tr(key, choice: store.languageChoice) }
    private var ink: Double { store.textOpacity }
    private var bg: Double { store.backgroundOpacity }
    private var v: HUDVisibility { store.visibility }

    private var showFullHeader: Bool { v.brandIcon || v.eventName || v.liveIndicator }
    private var showStatusLine: Bool { v.clickThroughStatus || v.moveHint }
    private var showNextColumn: Bool {
        !ClockCore.isFinalPhase(profile: store.active, now: store.now) &&
        (v.nextLabel || v.nextCountdown || v.nextTime)
    }
    private var showEndColumn: Bool { v.endLabel || v.endCountdown || v.endTime }
    private var hasEnabledMetric: Bool {
        let s = store.snapshot
        return (v.overallRank && s.rank != nil) || (v.groupRank && s.categoryRank != nil) ||
               (v.currentScore && s.score != nil)
    }

    var body: some View {
        let p = store.active
        VStack(alignment: .leading, spacing: store.cleanMode ? 8 : 10) {
            // A move handle always appears while repositioning, even when all
            // optional components are off and the panel is normally click-through.
            if store.isAdjustingPosition {
                adjustmentBar
            } else if !store.cleanMode {
                if showFullHeader { fullHeader(p.name) }
                if showStatusLine { statusLine }
            }

            countdowns(next: store.upcoming, end: store.end, zone: p.timeZoneID)

            if store.hasLiveScoreboard && hasEnabledMetric {
                if !store.cleanMode && v.divider {
                    Rectangle().fill(muted.opacity(0.22 * ink)).frame(height: 1)
                }
                metricRow(compact: store.cleanMode)
            }

            if v.latestSubmission, let submission = store.cleanLog.first {
                submissionLine(submission)
            } else if v.latestSubmission, store.hasLiveScoreboard,
                      let lastSolve = store.snapshot.lastSolveAt {
                Text(L10n.format("最后解题：{{time}}（API 只提供时间）", choice: store.languageChoice,
                                 values: ["time": ClockCore.format(lastSolve, "MM/dd HH:mm:ss", zone: p.timeZoneID)]))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(muted.opacity(ink))
                    .lineLimit(1)
            }

            if v.lastUpdated, let last = store.lastSuccessfulUpdate {
                HStack(spacing: 6) {
                    Text(L10n.format("上次成功读取：{{time}}", choice: store.languageChoice,
                                     values: ["time": ClockCore.format(last, "MM/dd HH:mm:ss", zone: p.timeZoneID)]))
                    if !store.hasLiveScoreboard { Text(t("(当前同步异常/配置已更改)")) }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(muted.opacity(ink)).lineLimit(1)
            }

            if !store.cleanMode && v.feedStatus {
                Text(L10n.status(store.snapshot.status, choice: store.languageChoice))
                    .font(.system(size: 9)).foregroundStyle(muted.opacity(ink)).lineLimit(1)
            }

            if v.timezone {
                Text(p.timeZoneID == "Asia/Hong_Kong" ? "HKT · UTC+8" : p.timeZoneID)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(muted.opacity(0.8 * ink))
            }
        }
        .padding(store.cleanMode ? 12 : 16)
        .frame(width: 474)
        .background(RoundedRectangle(cornerRadius: store.cleanMode ? 12 : 16)
            .fill(Color(red: 0.065, green: 0.060, blue: 0.10).opacity(bg)))
        .overlay {
            if v.border {
                RoundedRectangle(cornerRadius: store.cleanMode ? 12 : 16)
                    .stroke(accent.opacity((store.cleanMode ? 0.22 : 0.45) * bg), lineWidth: 1)
            }
        }
    }

    private var adjustmentBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                Text(t("调整位置 · 点击穿透暂时关闭 · 拖动此处"))
                Spacer()
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(accent.opacity(ink))
            .frame(height: 24)
            .overlay(HUDDragSurface(enabled: true))
            Button(t("完成")) { store.finishPositionAdjustment() }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .tint(accent)
        }
    }

    private func fullHeader(_ name: String) -> some View {
        HStack(spacing: 6) {
            if v.brandIcon {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent.opacity(ink))
            }
            if v.eventName {
                Text(t(name)).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent.opacity(ink)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if v.liveIndicator {
                Text(t("● LIVE HUD"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.green.opacity(ink))
            }
        }
        .frame(height: 23)
        .overlay {
            HUDDragSurface(enabled: !store.effectivePositionLocked && !store.effectiveClickThrough)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            if v.clickThroughStatus {
                Circle().fill((store.effectiveClickThrough ? Color.orange : Color.green).opacity(ink))
                    .frame(width: 7, height: 7)
                Text(t("点击穿透：") + t(store.clickThrough ? "开启" : "关闭"))
            }
            Spacer(minLength: 0)
            if v.moveHint {
                Text(t(store.effectiveClickThrough ? "菜单栏 → 调整位置" :
                        (store.effectivePositionLocked ? "位置已锁定" : "拖动顶部标题栏移动")))
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(muted.opacity(ink))
    }

    @ViewBuilder
    private func countdowns(next: Milestone?, end: Milestone?, zone: String) -> some View {
        if showNextColumn || showEndColumn {
            HStack(spacing: 12) {
                if showNextColumn {
                    HUDValue(label: "\(t("NEXT")) · \(next.map { t($0.title) } ?? t("没有下一阶段"))",
                             value: next.map { ClockCore.countdown(to: $0.date, now: store.now) } ?? "--:--:--",
                             detail: next.map { ClockCore.format($0.date, "MM/dd HH:mm", zone: zone) } ?? "—",
                             color: accent, textOpacity: ink,
                             showLabel: v.nextLabel, showValue: v.nextCountdown, showDetail: v.nextTime)
                }
                if showNextColumn && showEndColumn && v.divider {
                    Rectangle().fill(muted.opacity(0.20 * ink)).frame(width: 1, height: 58)
                }
                if showEndColumn {
                    HUDValue(label: "\(t("END")) · \(t("比赛结束"))",
                             value: end.map { ClockCore.countdown(to: $0.date, now: store.now) } ?? "--:--:--",
                             detail: end.map { ClockCore.format($0.date, "MM/dd HH:mm", zone: zone) } ?? "—",
                             color: .white, textOpacity: ink,
                             showLabel: v.endLabel, showValue: v.endCountdown, showDetail: v.endTime)
                }
            }
        }
    }

    private func rankChange(_ value: Int?) -> String? {
        guard let value = value else { return nil }
        return value > 0 ? "↑\(value)" : value < 0 ? "↓\(-value)" : "→0"
    }

    private func scoreChange(_ value: Double?) -> String? {
        guard let value = value else { return nil }
        if abs(value) < 0.005 { return "±0.00" }
        return String(format: "%+.2f", value)
    }

    private func changeColor(_ value: Double?) -> Color {
        guard let value = value else { return muted }
        return value > 0.004 ? .green : value < -0.004 ? .orange : muted
    }

    @ViewBuilder
    private func metricRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 5 : 12) {
            if v.overallRank, let rank = store.snapshot.rank {
                metric(t(store.snapshot.rankDerived ? "全场序位*" : "全场排名")
                       + (store.snapshot.overallRankTieCount > 1 ? t("（并列）") : ""), "#\(rank)",
                       change: v.overallRankDelta ? rankChange(store.scoreChanges?.overallRankImprovement) : nil,
                       changeColor: changeColor(store.scoreChanges?.overallRankImprovement.map(Double.init)), compact: compact)
            }
            if v.groupRank, let rank = store.snapshot.categoryRank {
                metric(t(store.snapshot.categoryRankDerived ? "组别序位*" : "组别排名")
                       + (store.snapshot.categoryRankTieCount > 1 ? t("（并列）") : ""), "#\(rank)",
                       change: v.groupRankDelta ? rankChange(store.scoreChanges?.categoryRankImprovement) : nil,
                       changeColor: changeColor(store.scoreChanges?.categoryRankImprovement.map(Double.init)), compact: compact)
            }
            if v.currentScore, let score = store.snapshot.score {
                metric(t("当前积分"), String(format: "%.2f", score),
                       change: v.scoreDelta ? scoreChange(store.scoreChanges?.score) : nil,
                       changeColor: changeColor(store.scoreChanges?.score), compact: compact)
            }
        }
    }

    private func metric(_ title: String, _ value: String, change: String?, changeColor: Color, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(muted.opacity(ink))
            Text(value).font(.system(size: compact ? 18 : 19, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(ink)).lineLimit(1).minimumScaleFactor(0.65)
            if let change = change {
                Text(t("Δ ") + change).font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(changeColor.opacity(ink)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 5 : 8)
        .background {
            if v.metricBackground {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07 * bg))
            }
        }
    }

    private func submissionLine(_ entry: SubmissionEntry) -> some View {
        HStack {
            Text(L10n.format("最近提交：{{challenge}} · {{result}}", choice: store.languageChoice,
                             values: ["challenge": entry.challenge, "result": t(entry.result)])).lineLimit(1)
            Spacer(minLength: 0)
            Text(ClockCore.format(entry.time, "HH:mm:ss", zone: store.active.timeZoneID))
                .lineLimit(1)
        }
        .font(.system(size: 10))
        .foregroundStyle(muted.opacity(ink))
    }
}

struct SettingsView: View {
    @ObservedObject var store: HUDStore
    @State private var newChallenge = ""
    @State private var newResult = "correct"
    @State private var newPoints = ""
    private func t(_ key: String) -> String { L10n.tr(key, choice: store.languageChoice) }

    private func binding<T>(_ keyPath: WritableKeyPath<ContestProfile, T>) -> Binding<T> {
        Binding(get: { store.active[keyPath: keyPath] },
                set: { value in store.edit { $0[keyPath: keyPath] = value } })
    }

    private func visibilityToggle(_ title: String, _ key: WritableKeyPath<HUDVisibility, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { store.visibility[keyPath: key] },
            set: { enabled in
                var options = store.visibility
                options[keyPath: key] = enabled
                store.visibility = options
            }
        )).toggleStyle(.checkbox)
    }

    private func visibilitySection(_ title: String, @ViewBuilder options: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                      alignment: .leading, spacing: 8) {
                options()
            }
        }
    }

    private var visibilitySettings: some View {
        GroupBox(t("HUD 元素 · 逐项显示 / 隐藏")) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text(t("每个项目单独控制。纯净模式仍隐藏完整模式的顶部标题与状态栏；调整位置时始终显示临时拖动条。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 10)
                    Button(t("恢复全部显示")) { store.visibility = HUDVisibility() }
                }
                visibilitySection(t("标题与状态（完整模式）")) {
                    visibilityToggle(t("赛事图标 ◆"), \.brandIcon)
                    visibilityToggle(t("赛事名称"), \.eventName)
                    visibilityToggle(t("LIVE HUD"), \.liveIndicator)
                    visibilityToggle(t("点击穿透状态"), \.clickThroughStatus)
                    visibilityToggle(t("移动位置提示"), \.moveHint)
                }
                visibilitySection(t("下一阶段")) {
                    visibilityToggle(t("下一阶段标签"), \.nextLabel)
                    visibilityToggle(t("下一阶段倒计时"), \.nextCountdown)
                    visibilityToggle(t("下一阶段目标时间"), \.nextTime)
                }
                visibilitySection(t("比赛结束")) {
                    visibilityToggle(t("结束标签"), \.endLabel)
                    visibilityToggle(t("结束倒计时"), \.endCountdown)
                    visibilityToggle(t("结束目标时间"), \.endTime)
                }
                visibilitySection(t("榜单及其变化（仅数据有效时显示）")) {
                    visibilityToggle(t("全场排名"), \.overallRank)
                    visibilityToggle(t("组别排名"), \.groupRank)
                    visibilityToggle(t("当前积分"), \.currentScore)
                    visibilityToggle(t("全场排名 Δ"), \.overallRankDelta)
                    visibilityToggle(t("组别排名 Δ"), \.groupRankDelta)
                    visibilityToggle(t("积分 Δ"), \.scoreDelta)
                }
                visibilitySection(t("补充信息与外观")) {
                    visibilityToggle(t("最近提交"), \.latestSubmission)
                    visibilityToggle(t("最后数据更新时间"), \.lastUpdated)
                    visibilityToggle(t("数据源状态（完整模式）"), \.feedStatus)
                    visibilityToggle(t("时区标记"), \.timezone)
                    visibilityToggle(t("分割线"), \.divider)
                    visibilityToggle(t("窗口边框"), \.border)
                    visibilityToggle(t("排名卡片背景"), \.metricBackground)
                }
                Text(t("注意：关闭「点击穿透状态」只隐藏 HUD 上的文字，不会关闭真正的点击穿透功能；仍可在设置或菜单栏修改。"))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }

    private var scoringExplanation: some View {
        GroupBox(t("动态计分与排名差值说明")) {
            VStack(alignment: .leading, spacing: 7) {
                Text(t("HKCERT 2026：单项成就得分 = 0.1 × M + 0.9 × M ÷ [1 + (max(0, x−1) ÷ 11.92201)^1.206069]。x 为解锁该成就的队伍数，M 为该成就的最高分（通常 500）；每项先保留两位小数，再相加。"))
                Text(t("HUD 显示的是排行榜接口返回的当前总分，不会把每次提交所记录的得分永久累加。随着其他队伍完成相同成就，总分可能降低。"))
                Text(t("积分 Δ = 本次成功读取的总分 − 上次成功读取的总分；全场 / 组别排名 Δ = 上次名次 − 本次名次。↑ 表示名次上升，↓ 表示下降，首次成功读取不显示 Δ。"))
                Text(t("全场序位* / 组别序位* 表示数据源没有提供相应官方名次，而是按返回列表推算。HKCERT 提供全场 rank，但组别序位* 是根据 S/T/O/I 队伍编号、总分及可用的最后解题时间推算；同分且无法明确分出先后时标记「并列」，不能作为官方晋级名次。"))
                Text(t("HKCERT 的 last_solve_at 只能表示最后解题时间；该接口不包含题目级别的提交历史。"))
                Text(t("更新时间为 HUD 在本机最后成功读取可用数据的时刻（按比赛时区显示），不等于比赛服务器最后修改榜单的时间。只有两次可比较的有效快照才显示 Δ。"))
                if let time = store.lastComparedUpdate {
                    Text(t("本次 Δ 的对比基准：") + ClockCore.format(time, "MM/dd HH:mm:ss", zone: store.active.timeZoneID))
                        .font(.system(.caption, design: .monospaced))
                }
            }.font(.caption).foregroundStyle(.secondary).padding(8)
        }
    }

    private func milestoneBinding(_ id: UUID) -> Binding<Milestone> {
        Binding(get: { store.active.milestones.first(where: { $0.id == id })
                     ?? Milestone(title: t("已删除"), date: Date(), kind: "phase") },
                set: { store.updateMilestone($0) })
    }

    var body: some View {
        let p = store.active
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(t("CTF HUD · 比赛控制中心")).font(.system(size: 21, weight: .bold))
                    Spacer()
                    Button(t("打开排行榜网页")) { store.openOfficialScoreboard() }
                }
                GroupBox(t("语言 / Language")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker(t("界面语言"), selection: $store.languageChoice) {
                            Text(t("系统默认")).tag("system")
                            Text(t("简体中文")).tag("zh-Hans")
                            Text(t("繁體中文")).tag("zh-Hant")
                            Text(t("英语")).tag("en")
                            Text(t("日语")).tag("ja")
                        }.pickerStyle(.menu)
                        Text(t("切换后立即生效，比赛和队伍资料不会被翻译或修改。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox(t("比赛配置")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Picker(t("当前比赛"), selection: Binding(get: { store.config.activeID },
                                set: { store.switchProfile(to: $0) })) {
                                ForEach(store.config.profiles, id: \.id) { prof in
                                    Text(t(prof.name)).tag(prof.id)
                                }
                            }
                            Button(t("＋新比赛")) { store.addProfile() }
                            Button(t("删除比赛")) { store.deleteProfile() }
                                .disabled(store.config.profiles.count < 2)
                        }
                        HStack {
                            Text(t("名称")).frame(width: 65, alignment: .leading)
                            TextField(t("比赛名称"), text: binding(\.name))
                        }
                        HStack {
                            Text(t("时区")).frame(width: 65, alignment: .leading)
                            TextField(t("Asia/Hong_Kong"), text: binding(\.timeZoneID))
                        }
                        Text(t("可创建多个比赛配置，分别设置时间轴和排名来源。所有资料保存在本机。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox(t("比赛时间轴 · 日期选择器使用比赛时区")) {
                    VStack(spacing: 9) {
                        ForEach(p.milestones.sorted(by: { $0.date < $1.date }), id: \.id) { stage in
                            let stageBinding = milestoneBinding(stage.id)
                            HStack(spacing: 8) {
                                Text(t(stage.kind == "start" ? "起" : stage.kind == "end" ? "终" : "阶"))
                                    .font(.system(size: 12, weight: .bold)).foregroundStyle(accent)
                                    .frame(width: 20)
                                TextField(t("阶段名称"), text: stageBinding.title)
                                    .frame(minWidth: 120)
                                DatePicker("", selection: stageBinding.date,
                                           displayedComponents: [.date, .hourAndMinute])
                                    .labelsHidden()
                                    .environment(\.timeZone, TimeZone(identifier: p.timeZoneID) ?? .current)
                                if stage.kind == "phase" {
                                    Button(role: .destructive) { store.removeMilestone(id: stage.id) } label: {
                                        Image(systemName: "minus.circle")
                                    }.buttonStyle(.borderless)
                                } else {
                                    Image(systemName: "lock").foregroundStyle(.secondary)
                                }
                            }
                        }
                        HStack {
                            Button(t("＋ 添加阶段")) { store.addMilestone() }
                            Spacer()
                            Text(t("阶段自动按时间排序")).font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle(t("进入最后阶段后隐藏「下一阶段」整栏，只保留比赛结束倒计时"),
                               isOn: binding(\.hideNextInFinalPhase))
                        Text(t("最后阶段从最后一个非结束节点开始；若只有开始和结束两个节点，则比赛开始后进入最后阶段。此选项只改变显示，不影响提醒。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox(t("声音提醒")) {
                    VStack(alignment: .leading, spacing: 9) {
                        Toggle(t("启用提醒声和系统通知"), isOn: binding(\.soundEnabled))
                        Toggle(t("每个阶段均提醒（否则只提醒比赛结束）"), isOn: binding(\.notifyAllStages))
                        HStack(spacing: 13) {
                            ForEach([120, 60, 30, 15, 5, 1], id: \.self) { mins in
                                Toggle(mins >= 60 ? "\(mins / 60)h" : "\(mins)m", isOn: Binding(
                                    get: { store.active.alertMinutes.contains(mins) },
                                    set: { enabled in store.edit { prof in
                                        if enabled { prof.alertMinutes = Array(Set(prof.alertMinutes + [mins])).sorted() }
                                        else { prof.alertMinutes.removeAll(where: { $0 == mins }) }
                                    } }
                                )).toggleStyle(.checkbox)
                            }
                        }
                    }.padding(8)
                }
                GroupBox(t("排行榜 · 协议 / Endpoint")) {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(t("官方榜单")).frame(width: 92, alignment: .leading)
                            TextField(t("https://example.org/scoreboard"), text: binding(\.scoreboardURL))
                        }
                        HStack {
                            Text(t("队伍标识")).frame(width: 92, alignment: .leading)
                            TextField(t("HKCTF 填 ID；CTFd 填队名或 account_id"), text: binding(\.teamName))
                        }
                        HStack {
                            Text(t("组别名称")).frame(width: 92, alignment: .leading)
                            TextField(t("可留空；CTFd 可使用 bracket_name"), text: binding(\.category))
                        }
                        Picker(t("数据协议"), selection: Binding(
                            get: { FeedProtocol.canonical(store.active.feedMode) },
                            set: { mode in
                                store.edit { profile in
                                    profile.feedMode = FeedProtocol.canonical(mode)
                                    if profile.feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                       let suggested = FeedProtocol.defaultEndpoint(mode) {
                                        profile.feedURL = suggested
                                    }
                                }
                            })) {
                            Text(t("关闭（手动查看网页）")).tag(FeedProtocol.off)
                            Text(t("HKCTF2026")).tag(FeedProtocol.hkctf2026)
                            Text(t("CTFd · 官方 Scoreboard API")).tag(FeedProtocol.ctfd)
                            Text(t("Custom JSON · 通用 JSON")).tag(FeedProtocol.custom)
                        }.pickerStyle(.menu)
                        HStack {
                            Text(t("JSON 端点")).frame(width: 92, alignment: .leading)
                            TextField(t("https://example.org/api/v1/scoreboard"), text: binding(\.feedURL))
                                .disabled(FeedProtocol.canonical(p.feedMode) == FeedProtocol.off)
                            Button(t("恢复协议默认值")) {
                                if let endpoint = FeedProtocol.defaultEndpoint(p.feedMode) {
                                    store.edit { $0.feedURL = endpoint }
                                }
                            }
                            .disabled(FeedProtocol.defaultEndpoint(p.feedMode) == nil)
                            Button(t("立即刷新")) { store.fetchScores(force: true) }
                                .disabled(FeedProtocol.canonical(p.feedMode) == FeedProtocol.off)
                        }
                        switch FeedProtocol.canonical(p.feedMode) {
                        case FeedProtocol.hkctf2026:
                            Text(t("HKCTF2026：默认读取公开的 teams[]、team_id、display_name、rank、score、last_solve_at。可覆盖 Endpoint；组别名次属推算值。"))
                        case FeedProtocol.ctfd:
                            Text(t("CTFd：填写该比赛实例的完整 /api/v1/scoreboard 地址；使用标准 success + data[] 和 pos、name、score、bracket_name 字段。"))
                        case FeedProtocol.custom:
                            Text(t("Custom JSON：接受 teams[] / data[] / standings[]；可选 submissions[]。字段格式见 README。"))
                        default:
                            Text(t("关闭同步：比赛时钟正常运行，不下载排行榜数据。"))
                        }
                        Text(t("仅向配置的端点发送无凭证 GET，每 120 秒检查一次。网址不可包含用户名、密码或 Token；私人凭证不要放入源码或仓库。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(t("状态：") + L10n.status(store.snapshot.status, choice: store.languageChoice)).font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                scoringExplanation
                GroupBox(t("提交记录 · 手动保存 / 可选 JSON 同步")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField(t("挑战名称"), text: $newChallenge)
                            Picker(t("结果"), selection: $newResult) {
                                Text(t("正确")).tag("correct")
                                Text(t("错误")).tag("incorrect")
                                Text(t("其他")).tag("other")
                            }.frame(width: 125)
                            TextField(t("得分（可选）"), text: $newPoints).frame(width: 95)
                            Button(t("记录")) {
                                let name = newChallenge.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !name.isEmpty else { return }
                                store.edit { $0.manualSubmissions.append(
                                    SubmissionEntry(time: Date(), challenge: name, result: newResult,
                                                    points: Int(newPoints))) }
                                newChallenge = ""; newPoints = ""
                            }.disabled(newChallenge.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        ForEach(Array(store.log.prefix(8)), id: \.id) { entry in
                            HStack {
                                Text(ClockCore.format(entry.time, "MM/dd HH:mm:ss", zone: p.timeZoneID))
                                    .font(.system(size: 11, design: .monospaced))
                                Text(entry.challenge).lineLimit(1)
                                Spacer()
                                Text(t(entry.result)).foregroundStyle(.secondary)
                                if p.manualSubmissions.contains(where: { $0.id == entry.id }) {
                                    Button(role: .destructive) {
                                        store.edit { $0.manualSubmissions.removeAll(where: { $0.id == entry.id }) }
                                    } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                                }
                            }.font(.system(size: 12))
                        }
                        if store.log.isEmpty {
                            Text(t("暂无提交。自动提交同步仅适用于提供授权 JSON 数据的比赛。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(8)
                }
                visibilitySettings
                GroupBox(t("悬浮窗 · 位置与外观")) {
                    VStack(alignment: .leading, spacing: 11) {
                        Picker(t("显示模式"), selection: $store.cleanMode) {
                            Text(t("完整模式")).tag(false)
                            Text(t("纯净模式")).tag(true)
                        }.pickerStyle(.segmented)
                        Text(t("纯净模式只保留两个倒计时及目标时间；排行榜的全场排名、组别排名、积分，和最近提交记录，仅在有相应真实数据时显示。"))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 15) {
                            Toggle(t("点击穿透"), isOn: $store.clickThrough)
                            Toggle(t("锁定位置"), isOn: $store.positionLocked)
                            Spacer()
                            Button(t(store.isAdjustingPosition ? "完成位置调整" : "调整 HUD 位置")) {
                                if store.isAdjustingPosition { store.finishPositionAdjustment() }
                                else { store.startPositionAdjustment() }
                            }
                            Button(t("重置到右上角")) { store.onResetWindowPosition?() }
                        }
                        HStack(spacing: 12) {
                            Text(t("背景透明度")).frame(width: 90, alignment: .leading)
                            Slider(value: Binding(get: { 1.0 - store.backgroundOpacity },
                                set: { store.backgroundOpacity = 1.0 - $0 }), in: 0.0...1.0, step: 0.05)
                            Text("\(Int((1.0 - store.backgroundOpacity) * 100))%")
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 48, alignment: .trailing)
                        }
                        HStack(spacing: 12) {
                            Text(t("文字透明度")).frame(width: 90, alignment: .leading)
                            Slider(value: Binding(get: { 1.0 - store.textOpacity },
                                set: { store.textOpacity = 1.0 - $0 }), in: 0.0...0.90, step: 0.05)
                            Text("\(Int((1.0 - store.textOpacity) * 100))%")
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 48, alignment: .trailing)
                        }
                        Text(t("透明度 0% = 完全不透明；100% = 完全透明。背景与文字独立调节，不再降低整个窗口的不透明度。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(store.isAdjustingPosition
                            ? t("● 位置调整中：点击穿透已临时关闭、位置锁定已临时解除。直接拖动 HUD 顶部标题栏；按「完成位置调整」恢复原设置。")
                            : L10n.format("● 当前：点击穿透{{click}} · 位置{{lock}}。移动位置会自动保存，下次启动恢复。",
                                     choice: store.languageChoice, values: [
                                        "click": t(store.clickThrough ? "开启" : "关闭"),
                                        "lock": t(store.positionLocked ? "锁定" : "可移动")]))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(t("配置：~/Library/Application Support/CTFHUD/config.json；窗口偏好单独保存在 macOS UserDefaults。"))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }.padding(8)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 760, minHeight: 610)
    }
}

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class CTFApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = HUDStore()
    var panel: HUDPanel!
    private var hostingView: NSHostingView<HUDView>!
    var settings: NSWindow!
    var statusItem: NSStatusItem!
    var timer: Timer?
    private var restoringWindowPosition = false
    private var adjustItem: NSMenuItem?
    private var clickThroughItem: NSMenuItem?
    private var lockItem: NSMenuItem?
    private var cleanModeItem: NSMenuItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        hostingView = NSHostingView(rootView: HUDView(store: store))
        let frame = NSRect(x: 0, y: 0, width: 474, height: 268)
        panel = HUDPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = false  // Dragging is header-only.
        panel.delegate = self
        panel.hidesOnDeactivate = false
        restoringWindowPosition = true
        updateHUDSize()
        restoreWindowPosition()
        restoringWindowPosition = false
        store.onWindowStateChanged = { [weak self] in self?.applyWindowState() }
        store.onResetWindowPosition = { [weak self] in self?.resetWindowPosition() }
        applyWindowState()
        panel.orderFrontRegardless()
        settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 690),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable],
                            backing: .buffered, defer: false)
        // The control center is a persistent window. Closing it must not
        // release the NSWindow while the menu-bar controller still owns it.
        // AppKit's default release-on-close behavior can otherwise leave the
        // next openSettings() call talking to a deallocated window.
        settings.isReleasedWhenClosed = false
        settings.delegate = self
        settings.title = L10n.tr("CTF HUD 设置", choice: store.languageChoice)
        settings.contentView = NSHostingView(rootView: SettingsView(store: store))
        settings.center()
        setupMenu()
        store.onLanguageChanged = { [weak self] in
            guard let self = self else { return }
            self.settings.title = L10n.tr("CTF HUD 设置", choice: self.store.languageChoice)
            self.setupMenu()
            self.updateHUDSize()
        }
        timer = Timer.scheduledTimer(timeInterval: 1, target: self,
                                     selector: #selector(tick), userInfo: nil, repeats: true)
        if let timer = timer { RunLoop.main.add(timer, forMode: .common) }
        store.fetchScores(force: true)
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.tr(title, choice: store.languageChoice), action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func setupMenu() {
        // Reuse the one status item when language changes. Allocating a fresh
        // NSStatusItem here on each switch leaks menu-bar items and menus.
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        statusItem.button?.title = "⏱ CTF"
        let menu = NSMenu()
        menu.addItem(menuItem("打开比赛控制中心…", #selector(openSettings)))
        menu.addItem(menuItem("打开官方排行榜", #selector(openLeaderboard)))
        menu.addItem(menuItem("刷新排名", #selector(refreshScores)))
        menu.addItem(.separator())
        menu.addItem(menuItem("显示 / 隐藏 HUD", #selector(toggleHUD)))
        cleanModeItem = menuItem("纯净模式", #selector(toggleCleanMode))
        menu.addItem(cleanModeItem!)
        adjustItem = menuItem("调整悬浮窗位置…", #selector(togglePositionAdjustment))
        menu.addItem(adjustItem!)
        clickThroughItem = menuItem("点击穿透", #selector(toggleClickThrough))
        menu.addItem(clickThroughItem!)
        lockItem = menuItem("锁定位置", #selector(togglePositionLock))
        menu.addItem(lockItem!)
        menu.addItem(menuItem("位置重置到右上角", #selector(resetWindowPositionAction)))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出 CTF HUD", #selector(quit)))
        statusItem.menu = menu
        updateMenuState()
    }

    private func applyWindowState() {
        guard panel != nil else { return }
        panel.ignoresMouseEvents = store.effectiveClickThrough
        // Never change panel.alphaValue: this would also fade its text.
        panel.alphaValue = 1.0
        DispatchQueue.main.async { [weak self] in self?.updateHUDSize() }
        updateMenuState()
    }

    private func updateHUDSize() {
        guard panel != nil, hostingView != nil else { return }
        // Dynamic height allows unavailable ranking/submission rows to vanish,
        // without leaving a blank window area in clean mode.
        hostingView.layoutSubtreeIfNeeded()
        let desired = hostingView.fittingSize
        let height = ceil(max(96, desired.height))
        guard abs(panel.frame.height - height) > 2 else { return }
        let old = panel.frame
        let wasRestoring = restoringWindowPosition
        restoringWindowPosition = true
        let desiredOrigin = safeOrigin(NSPoint(x: old.minX, y: old.maxY - height),
                                       size: NSSize(width: old.width, height: height))
        panel.setFrame(NSRect(origin: desiredOrigin,
                              size: NSSize(width: old.width, height: height)),
                       display: true, animate: false)
        restoringWindowPosition = wasRestoring
        if !wasRestoring {
            store.windowOrigin = WindowOrigin(x: Double(panel.frame.minX),
                                              y: Double(panel.frame.minY))
        }
    }

    private func updateMenuState() {
        cleanModeItem?.title = L10n.format("纯净模式：{{state}}", choice: store.languageChoice,
                                          values: ["state": L10n.tr(store.cleanMode ? "开启" : "关闭", choice: store.languageChoice)])
        cleanModeItem?.state = store.cleanMode ? .on : .off
        adjustItem?.title = L10n.tr(store.isAdjustingPosition ? "✓ 完成位置调整" : "调整悬浮窗位置…", choice: store.languageChoice)
        clickThroughItem?.title = store.isAdjustingPosition
            ? L10n.format("点击穿透：临时关闭（原设置{{state}}）", choice: store.languageChoice,
                           values: ["state": L10n.tr(store.clickThrough ? "开" : "关", choice: store.languageChoice)])
            : L10n.format("点击穿透：{{state}}", choice: store.languageChoice,
                           values: ["state": L10n.tr(store.clickThrough ? "开启" : "关闭", choice: store.languageChoice)])
        clickThroughItem?.state = store.clickThrough ? .on : .off
        lockItem?.title = store.isAdjustingPosition
            ? L10n.tr("位置锁定：临时解除", choice: store.languageChoice)
            : L10n.format("位置锁定：{{state}}", choice: store.languageChoice,
                           values: ["state": L10n.tr(store.positionLocked ? "开启" : "关闭", choice: store.languageChoice)])
        lockItem?.state = store.positionLocked ? .on : .off
    }

    private func safeOrigin(_ candidate: NSPoint, size: NSSize) -> NSPoint {
        let wanted = NSRect(origin: candidate, size: size)
        let screens = NSScreen.screens
        guard let screen = screens.first(where: {
            $0.visibleFrame.intersection(wanted).width > 80 &&
            $0.visibleFrame.intersection(wanted).height > 40
        }) ?? NSScreen.main ?? screens.first else { return candidate }
        let area = screen.visibleFrame
        return NSPoint(x: max(area.minX, min(candidate.x, area.maxX - size.width)),
                       y: max(area.minY, min(candidate.y, area.maxY - size.height)))
    }

    private func defaultOrigin() -> NSPoint {
        guard let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            return NSPoint(x: 100, y: 100)
        }
        return NSPoint(x: area.maxX - panel.frame.width - 20,
                       y: area.maxY - panel.frame.height - 20)
    }

    private func restoreWindowPosition() {
        let saved = store.windowOrigin.map { NSPoint(x: $0.x, y: $0.y) }
        let origin = safeOrigin(saved ?? defaultOrigin(), size: panel.frame.size)
        panel.setFrameOrigin(origin)
    }

    private func resetWindowPosition() {
        restoringWindowPosition = true
        panel.setFrameOrigin(safeOrigin(defaultOrigin(), size: panel.frame.size))
        restoringWindowPosition = false
        store.windowOrigin = WindowOrigin(x: Double(panel.frame.minX), y: Double(panel.frame.minY))
    }

    func windowDidMove(_ notification: Notification) {
        // We are also the control center's delegate. Only a HUD movement
        // should update the saved overlay position.
        guard !restoringWindowPosition,
              let movingWindow = notification.object as? NSWindow,
              movingWindow === panel else { return }
        store.windowOrigin = WindowOrigin(x: Double(panel.frame.minX), y: Double(panel.frame.minY))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === settings else { return true }
        // Hide rather than close/destroy the SwiftUI hosting window. The same
        // object can be reopened indefinitely from the status-bar menu.
        sender.orderOut(nil)
        return false
    }

    @objc private func tick() {
        store.tick()
        DispatchQueue.main.async { [weak self] in self?.updateHUDSize() }
    }
    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        settings.makeKeyAndOrderFront(nil)
    }
    @objc private func openLeaderboard() { store.openOfficialScoreboard() }
    @objc private func refreshScores() { store.fetchScores(force: true) }
    @objc private func toggleHUD() {
        if panel.isVisible { panel.orderOut(nil); store.isVisible = false }
        else { panel.orderFrontRegardless(); store.isVisible = true }
    }
    @objc private func toggleCleanMode() { store.cleanMode.toggle() }
    @objc private func toggleClickThrough() { store.clickThrough.toggle() }
    @objc private func togglePositionLock() { store.positionLocked.toggle() }
    @objc private func togglePositionAdjustment() {
        if store.isAdjustingPosition { store.finishPositionAdjustment() }
        else {
            if !panel.isVisible { panel.orderFrontRegardless(); store.isVisible = true }
            store.startPositionAdjustment()
        }
    }
    @objc private func resetWindowPositionAction() { resetWindowPosition() }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = CTFApp()
app.delegate = delegate
app.run()
