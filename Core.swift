import Foundation

struct Milestone: Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var date: Date
    var kind: String // start, phase, end
}

struct SubmissionEntry: Codable, Equatable {
    var id: UUID = UUID()
    var time: Date
    var challenge: String
    var result: String
    var points: Int?
}

// Public scoreboard protocols. The identifier is independent of a particular
// contest profile or team. Legacy settings are normalized on load.
enum FeedProtocol {
    static let off = "off"
    static let hkctf2026 = "HKCTF2026"
    static let ctfd = "CTFd"
    static let custom = "CustomJSON"

    static func canonical(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "hkctf2026", "hkcert": return hkctf2026
        case "ctfd": return ctfd
        case "json", "customjson", "custom": return custom
        default: return off
        }
    }

    static func defaultEndpoint(_ value: String) -> String? {
        if canonical(value) == hkctf2026 {
            return "https://platform.ctf.hkcert.org/api/v1/leaderboard"
        }
        // CTFd instances have no universal hostname; users supply the full URL.
        return nil
    }

    static func isValidEndpoint(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil else { return false }
        if scheme == "https" { return true }
        // Only loopback endpoints may use plaintext HTTP during local testing.
        return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
    }
}

struct ContestProfile: Codable {
    var id: UUID = UUID()
    var name: String
    var timeZoneID: String
    var milestones: [Milestone]
    var teamName: String
    var category: String
    var feedMode: String // off, ctfd, json
    var feedURL: String
    var scoreboardURL: String
    var notifyAllStages: Bool
    var soundEnabled: Bool
    var alertMinutes: [Int]
    var manualSubmissions: [SubmissionEntry]
    // When the last stage begins, hide the entire NEXT column.
    var hideNextInFinalPhase: Bool

    init(id: UUID = UUID(), name: String, timeZoneID: String,
         milestones: [Milestone], teamName: String, category: String,
         feedMode: String, feedURL: String, scoreboardURL: String,
         notifyAllStages: Bool, soundEnabled: Bool, alertMinutes: [Int],
         manualSubmissions: [SubmissionEntry], hideNextInFinalPhase: Bool = true) {
        self.id = id; self.name = name; self.timeZoneID = timeZoneID
        self.milestones = milestones; self.teamName = teamName
        self.category = category; self.feedMode = FeedProtocol.canonical(feedMode)
        self.feedURL = feedURL; self.scoreboardURL = scoreboardURL
        self.notifyAllStages = notifyAllStages; self.soundEnabled = soundEnabled
        self.alertMinutes = alertMinutes; self.manualSubmissions = manualSubmissions
        self.hideNextInFinalPhase = hideNextInFinalPhase
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, timeZoneID, milestones, teamName, category, feedMode,
             feedURL, scoreboardURL, notifyAllStages, soundEnabled,
             alertMinutes, manualSubmissions, hideNextInFinalPhase
    }

    // v1.5 config.json did not contain hideNextInFinalPhase. Decode it
    // explicitly so an upgrade never silently replaces the user's profiles.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            timeZoneID: try c.decode(String.self, forKey: .timeZoneID),
            milestones: try c.decode([Milestone].self, forKey: .milestones),
            teamName: try c.decode(String.self, forKey: .teamName),
            category: try c.decode(String.self, forKey: .category),
            feedMode: try c.decode(String.self, forKey: .feedMode),
            feedURL: try c.decode(String.self, forKey: .feedURL),
            scoreboardURL: try c.decode(String.self, forKey: .scoreboardURL),
            notifyAllStages: try c.decode(Bool.self, forKey: .notifyAllStages),
            soundEnabled: try c.decode(Bool.self, forKey: .soundEnabled),
            alertMinutes: try c.decode([Int].self, forKey: .alertMinutes),
            manualSubmissions: try c.decode([SubmissionEntry].self, forKey: .manualSubmissions),
            hideNextInFinalPhase: try c.decodeIfPresent(Bool.self, forKey: .hideNextInFinalPhase) ?? true
        )
    }
}

struct AppConfig: Codable {
    var activeID: UUID
    var profiles: [ContestProfile]
}

struct ScoreboardTeam: Equatable {
    var name: String
    var score: Double?
    var rank: Int?
    var category: String?
    var identifier: String? = nil // optional team_id or CTFd account_id
}

struct ScoreSnapshot {
    var rank: Int?
    var categoryRank: Int?
    var score: Double?
    var submissions: [SubmissionEntry]
    var status: String
    // If the feed provides no official category rank, the rank is estimated
    // from the returned rows. It may be incomplete for paginated feeds.
    var categoryRankDerived = false
    var rankDerived = false
    // HKCERT ranks teams with the same score equally; group ranking is derived,
    // so ties must be labelled rather than presenting a unique placement.
    var overallRankTieCount = 1
    var categoryRankTieCount = 1
    var lastSolveAt: Date? = nil
}

// Positive rank improvement means moving toward rank #1. Scores may decrease
// without any new submission because many contests use dynamic scoring.
struct ScoreChanges: Equatable {
    var score: Double?
    var overallRankImprovement: Int?
    var categoryRankImprovement: Int?

    static func between(_ prior: ScoreSnapshot, _ current: ScoreSnapshot) -> ScoreChanges {
        ScoreChanges(
            score: (prior.score != nil && current.score != nil) ? current.score! - prior.score! : nil,
            overallRankImprovement: (prior.rank != nil && current.rank != nil) ? prior.rank! - current.rank! : nil,
            categoryRankImprovement: (prior.categoryRank != nil && current.categoryRank != nil &&
                                      prior.categoryRankTieCount == 1 && current.categoryRankTieCount == 1)
                                     ? prior.categoryRank! - current.categoryRank! : nil
        )
    }
}

// All visual elements may be independently hidden. If all are hidden, the
// menu bar still provides access to settings and the move handle.
// The window layout is independent of the full/clean content preference.
// Persisting it separately lets the same competition use either presentation.
enum HUDLayoutMode: String, Codable, CaseIterable {
    case floating
    case topBar
}

// Pure sizing logic, testable without AppKit on non-macOS hosts.
enum HUDBarSizing {
    static let compactHeight: Double = 42
    static func clampedFraction(_ requested: Double) -> Double {
        guard requested.isFinite else { return 0.92 }
        return min(0.98, max(0.70, requested))
    }
    static func barWidth(available: Double, fraction: Double) -> Double {
        let inner = max(1, available - 16)
        return min(inner, max(1, available * clampedFraction(fraction)))
    }
}

struct HUDVisibility: Codable, Equatable {
    var brandIcon = true
    var eventName = true
    var liveIndicator = true
    var clickThroughStatus = true
    var moveHint = true
    var nextLabel = true
    var nextCountdown = true
    var nextTime = true
    var endLabel = true
    var endCountdown = true
    var endTime = true
    var divider = true
    var overallRank = true
    var groupRank = true
    var currentScore = true
    var overallRankDelta = true
    var groupRankDelta = true
    var scoreDelta = true
    var latestSubmission = true
    var lastUpdated = true
    var feedStatus = true
    var timezone = true
    var border = true
    var metricBackground = true
}


enum ClockCore {
    // HKCERT 2026 per-achievement dynamic scoring. x = number of distinct teams
    // unlocking the achievement; sum separately rounded achievement values.
    static func achievementPoints(maxPoints: Double, solves: Int) -> Double {
        guard maxPoints > 0, solves > 0 else { return 0 }
        let ratio = Double(max(0, solves - 1)) / 11.92201
        let raw = 0.1 * maxPoints + 0.9 * maxPoints / (1 + pow(ratio, 1.206069))
        // Competition uses conventional half-up to 2 decimals for nonnegative scores.
        return (raw * 100).rounded(.toNearestOrAwayFromZero) / 100
    }

    static func achievementTotal(_ entries: [(maxPoints: Double, solves: Int)]) -> Double {
        entries.reduce(0) { $0 + achievementPoints(maxPoints: $1.maxPoints, solves: $1.solves) }
    }

    static func formatter(_ format: String, zone: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: zone) ?? TimeZone(secondsFromGMT: 8 * 3600)!
        f.dateFormat = format
        f.isLenient = false
        return f
    }

    static func date(_ value: String, zone: String) -> Date? {
        formatter("yyyy-MM-dd HH:mm", zone: zone).date(from: value)
    }

    static func format(_ date: Date, _ pattern: String, zone: String) -> String {
        formatter(pattern, zone: zone).string(from: date)
    }

    static func countdown(to target: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(ceil(target.timeIntervalSince(now))))
        return String(format: "%02d:%02d:%02d", seconds / 3600,
                      (seconds % 3600) / 60, seconds % 60)
    }

    static func cleanName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // No real teams, schools, personal schedule or private submissions are
    // baked into the public build. Local user settings are not part of the ZIP.
    static func initialConfig(now: Date = Date()) -> AppConfig {
        let event = newProfile(now: now)
        return AppConfig(activeID: event.id, profiles: [event])
    }

    static func newProfile(now: Date = Date()) -> ContestProfile {
        let zone = "Asia/Hong_Kong"
        let start = Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(3600)
        let end = start.addingTimeInterval(8 * 3600)
        return ContestProfile(name: "新比赛（请设置）", timeZoneID: zone,
            milestones: [Milestone(title: "比赛开始", date: start, kind: "start"),
                         Milestone(title: "比赛结束", date: end, kind: "end")],
            teamName: "", category: "", feedMode: FeedProtocol.off, feedURL: "", scoreboardURL: "",
            notifyAllStages: true, soundEnabled: true,
            alertMinutes: [120, 60, 30, 15, 5, 1], manualSubmissions: [])
    }

    static func isFinalPhase(profile: ContestProfile, now: Date) -> Bool {
        guard profile.hideNextInFinalPhase,
              let end = profile.milestones.filter({ $0.kind == "end" }).map(\.date).max() else {
            return false
        }
        // The last non-END milestone is the start of the final segment.
        // If there are no custom phases, that milestone is the contest start.
        guard let finalPhaseStart = profile.milestones
            .filter({ $0.kind != "end" && $0.date < end })
            .map(\.date).max() else { return false }
        return now >= finalPhaseStart
    }

    static func dueAlerts(profile: ContestProfile, previous: Date?, now: Date, fired: Set<String>) -> [(key: String, stage: Milestone, minutes: Int)] {
        var results: [(String, Milestone, Int)] = []
        // Do not replay old alerts on launch. On wake, coalesce missed thresholds per milestone.
        let lowerBound = previous ?? now.addingTimeInterval(-1.5)
        for stage in profile.milestones where profile.notifyAllStages || stage.kind == "end" {
            guard stage.date > now else { continue }
            let matches = profile.alertMinutes.sorted().compactMap { minutes -> (String, Milestone, Int)? in
                let at = stage.date.addingTimeInterval(TimeInterval(-minutes * 60))
                let key = "\(profile.id.uuidString)/\(stage.id.uuidString)/\(minutes)"
                if at > lowerBound && at <= now && !fired.contains(key) { return (key, stage, minutes) }
                return nil
            }
            if let nearest = matches.first { results.append(nearest) }
        }
        return results
    }

    // Supports a public CTFd scoreboard response or a simple custom JSON feed.
    // No website scraping, no cookies/passwords and no undocumented endpoints.
    static func parseScoreboard(_ data: Data, mode: String, teamName: String, category: String) throws -> ScoreSnapshot {
        let root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let payload = root as? [String: Any]
        if let valid = payload?["success"] as? Bool, !valid {
            throw NSError(domain: "CTFHUD", code: 2, userInfo: [NSLocalizedDescriptionKey: "API 返回 success=false"])
        }
        let entries: [[String: Any]]
        if let array = root as? [[String: Any]] { entries = array }
        else if let a = payload?["teams"] as? [[String: Any]] { entries = a }
        else if let a = payload?["data"] as? [[String: Any]] { entries = a }
        else if let a = payload?["standings"] as? [[String: Any]] { entries = a }
        else { throw NSError(domain: "CTFHUD", code: 3, userInfo: [NSLocalizedDescriptionKey: "没有找到 teams、data 或 standings 数组"]) }

        func intValue(_ any: Any?) -> Int? {
            if let num = any as? NSNumber { return num.intValue }
            if let str = any as? String { return Int(str) }
            return nil
        }
        func doubleValue(_ any: Any?) -> Double? {
            if let num = any as? NSNumber { return num.doubleValue }
            if let str = any as? String { return Double(str) }
            return nil
        }
        // HKCERT 2026 public leaderboard JSON:
        // {"teams":[{"team_id":"S_DEMO","display_name":"S_DEMO - Example",
        //            "rank":2,"score":0,"last_solve_at":null}, ...]}
        // No official category rank or per-challenge submission history in this API.
        if FeedProtocol.canonical(mode) == FeedProtocol.hkctf2026 {
            let key = cleanName(teamName)
            guard !key.isEmpty else {
                return ScoreSnapshot(rank: nil, categoryRank: nil, score: nil,
                                     submissions: [], status: "请填写自己的队伍 ID")
            }
            guard let rawTeam = entries.first(where: { row in
                cleanName(row["team_id"] as? String ?? "") == key ||
                cleanName(row["display_name"] as? String ?? "") == key
            }) else {
                return ScoreSnapshot(rank: nil, categoryRank: nil, score: nil,
                                     submissions: [], status: "排行榜未找到队伍 ID 或名称")
            }
            let teamID = rawTeam["team_id"] as? String ?? ""
            let groupCode = String(teamID.prefix(1)).uppercased()
            let groupCodes = Set(["S", "T", "O", "I"])
            let teamScore = doubleValue(rawTeam["score"])
            let overallRank = intValue(rawTeam["rank"])
            let groupRows = groupCodes.contains(groupCode) ? entries.filter {
                (($0["team_id"] as? String ?? "").uppercased().hasPrefix(groupCode))
            } : []

            // If tie-break timestamps are missing, use the *shared* best group
            // position: one plus the count of definitively higher-scoring teams.
            // When both timestamps are available, an earlier solve is ahead.
            // This is an estimate, not an official group rank.
            let parsedSolve: (Any?) -> Date? = { value in
                guard let raw = value as? String else { return nil }
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = iso.date(from: raw) { return date }
                iso.formatOptions = [.withInternetDateTime]
                return iso.date(from: raw)
            }
            let lastSolve = parsedSolve(rawTeam["last_solve_at"])
            var before = 0
            var tieCount = 0
            if let score = teamScore {
                for row in groupRows {
                    guard let other = doubleValue(row["score"]) else { continue }
                    if other > score + 0.000001 { before += 1; continue }
                    if abs(other - score) < 0.000001 {
                        let theirLast = parsedSolve(row["last_solve_at"])
                        if let currentLast = lastSolve, let otherLast = theirLast,
                           otherLast < currentLast { before += 1 }
                        else if lastSolve == nil || theirLast == nil || theirLast == lastSolve {
                            tieCount += 1
                        }
                    }
                }
            }
            let groupRank: Int? = teamScore != nil && !groupRows.isEmpty ? before + 1 : nil
            // The overall rank is directly supplied by the organiser; equal
            // ranks must remain tied and never be replaced by list position.
            let overallTies = overallRank.map { target in
                entries.filter { intValue($0["rank"]) == target }.count
            } ?? 1
            return ScoreSnapshot(rank: overallRank, categoryRank: groupRank,
                                 score: teamScore, submissions: [], status: "已同步",
                                 categoryRankDerived: groupRank != nil,
                                 rankDerived: false,
                                 overallRankTieCount: max(1, overallTies),
                                 categoryRankTieCount: max(1, tieCount),
                                 lastSolveAt: lastSolve)
        }

        func identifier(_ item: [String: Any]) -> String? {
            if let string = item["team_id"] as? String { return string }
            if let string = item["account_id"] as? String { return string }
            if let number = item["account_id"] as? NSNumber { return number.stringValue }
            return nil
        }
        let teams: [ScoreboardTeam] = entries.compactMap { item in
            guard let name = (item["name"] ?? item["team"] ?? item["team_name"] ?? item["display_name"]
                              ?? item["team_id"]) as? String else { return nil }
            return ScoreboardTeam(name: name, score: doubleValue(item["score"] ?? item["points"]),
                rank: intValue(item["pos"] ?? item["rank"] ?? item["place"]),
                category: (item["category"] ?? item["bracket_name"] ?? item["division"] ?? item["group"]) as? String,
                identifier: identifier(item))
        }
        let ordered = teams.sorted { ($0.rank ?? Int.max, -($0.score ?? -1), $0.name) < ($1.rank ?? Int.max, -($1.score ?? -1), $1.name) }
        let key = cleanName(teamName)
        func matches(_ team: ScoreboardTeam) -> Bool {
            cleanName(team.name) == key || cleanName(team.identifier ?? "") == key
        }
        guard !key.isEmpty else {
            return ScoreSnapshot(rank: nil, categoryRank: nil, score: nil, submissions: [], status: "请先设置队伍名称")
        }
        guard let team = ordered.first(where: matches) else {
            return ScoreSnapshot(rank: nil, categoryRank: nil, score: nil, submissions: [], status: "排行榜中未找到队伍")
        }
        let derivedOverall = ordered.firstIndex(where: matches).map { $0 + 1 }
        let overall = team.rank ?? derivedOverall
        let categoryKey = cleanName(category)
        let rawTeam = entries.first(where: {
            cleanName(($0["name"] ?? $0["team"] ?? $0["team_name"] ?? $0["display_name"]
                       ?? $0["team_id"]) as? String ?? "") == key ||
            cleanName(identifier($0) ?? "") == key
        })
        let officialCategoryRank = intValue(rawTeam?["category_rank"] ?? rawTeam?["division_rank"] ?? rawTeam?["group_rank"])
        let categoryTeams = ordered.filter { cleanName($0.category ?? "") == categoryKey }
        let derivedCategoryRank: Int? = categoryKey.isEmpty ? nil : categoryTeams.firstIndex(where: matches).map { $0 + 1 }
        // Do not treat a rank from unrelated group rows as a real category rank.
        let matchingCategory = team.category.map { cleanName($0) == categoryKey } ?? true
        let categoryRank: Int? = categoryKey.isEmpty || !matchingCategory ? nil : (officialCategoryRank ?? derivedCategoryRank)

        var submissions: [SubmissionEntry] = []
        if FeedProtocol.canonical(mode) == FeedProtocol.custom, let rows = payload?["submissions"] as? [[String: Any]] {
            submissions = rows.compactMap { item in
                if let owner = (item["team"] ?? item["team_name"]) as? String,
                   cleanName(owner) != key && cleanName(owner) != cleanName(team.name) { return nil }
                guard let challenge = (item["challenge"] ?? item["name"]) as? String else { return nil }
                let result = (item["result"] ?? item["status"]) as? String ?? "提交"
                var stamp = Date()
                if let epoch = intValue(item["timestamp"]) { stamp = Date(timeIntervalSince1970: TimeInterval(epoch)) }
                else if let iso = item["time"] as? String {
                    let f = ISO8601DateFormatter()
                    if let parsed = f.date(from: iso) { stamp = parsed }
                }
                return SubmissionEntry(time: stamp, challenge: challenge, result: result,
                                       points: intValue(item["points"]))
            }.sorted { $0.time > $1.time }
        }
        return ScoreSnapshot(rank: overall, categoryRank: categoryRank, score: team.score,
                             submissions: submissions, status: "已同步",
                             categoryRankDerived: categoryRank != nil && officialCategoryRank == nil && derivedCategoryRank != nil,
                             rankDerived: team.rank == nil && derivedOverall != nil)
    }
}
