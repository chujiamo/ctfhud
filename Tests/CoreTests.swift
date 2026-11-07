import Foundation

// All names and identifiers in these fixtures are fictitious.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct CoreTestRunner {
    static func main() throws {
        check(FeedProtocol.canonical("hkcert") == FeedProtocol.hkctf2026, "migrate old HK code")
        check(FeedProtocol.canonical("HKCTF2026") == FeedProtocol.hkctf2026, "new HK protocol")
        check(FeedProtocol.canonical("ctfd") == FeedProtocol.ctfd, "old CTFd protocol")
        check(FeedProtocol.canonical("json") == FeedProtocol.custom, "old custom JSON protocol")
        check(FeedProtocol.canonical("none") == FeedProtocol.off, "invalid protocol disables")
        check(FeedProtocol.defaultEndpoint(FeedProtocol.hkctf2026)?.hasSuffix("/api/v1/leaderboard") == true,
              "HK protocol default endpoint")
        check(FeedProtocol.defaultEndpoint(FeedProtocol.ctfd) == nil,
              "CTFd requires instance host")
        check(FeedProtocol.isValidEndpoint("https://ctf.example.org/api/v1/scoreboard"), "HTTPS allowed")
        check(FeedProtocol.isValidEndpoint("http://localhost:8000/api/v1/scoreboard"), "localhost HTTP allowed")
        check(!FeedProtocol.isValidEndpoint("http://ctf.example.org/api/v1/scoreboard"), "remote HTTP rejected")
        let withCredential = "https://demo:" + "placeholder" + "@" + "ctf.example.org/scoreboard"
        check(!FeedProtocol.isValidEndpoint(withCredential), "URL credentials rejected")
        check(!FeedProtocol.isValidEndpoint("https://ctf.example.org/scoreboard#token"), "fragments rejected")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let initial = ClockCore.initialConfig(now: now)
        let newContest = initial.profiles[0]
        check(newContest.teamName.isEmpty && newContest.manualSubmissions.isEmpty, "no personal defaults")
        check(newContest.feedMode == FeedProtocol.off, "public build does not auto-connect")
        check(newContest.milestones.count == 2, "initial start/end")
        check(!ClockCore.isFinalPhase(profile: newContest, now: now), "before contest: show next")
        let start = newContest.milestones.first(where: { $0.kind == "start" })!.date
        let end = newContest.milestones.first(where: { $0.kind == "end" })!.date
        check(ClockCore.isFinalPhase(profile: newContest, now: start), "without custom stages, start begins last phase")
        check(ClockCore.countdown(to: Date(timeIntervalSince1970: 200),
                                  now: Date(timeIntervalSince1970: 0)) == "00:03:20", "countdown")

        var staged = newContest
        let stage1 = Milestone(title: "阶段 A", date: start.addingTimeInterval(3600), kind: "phase")
        let stage2 = Milestone(title: "阶段 B", date: start.addingTimeInterval(7200), kind: "phase")
        staged.milestones.append(contentsOf: [stage1, stage2])
        check(!ClockCore.isFinalPhase(profile: staged, now: stage1.date.addingTimeInterval(2)), "first phase still shows next")
        check(!ClockCore.isFinalPhase(profile: staged, now: stage2.date.addingTimeInterval(-1)), "before last stage")
        check(ClockCore.isFinalPhase(profile: staged, now: stage2.date), "after last stage hide next")
        check(ClockCore.isFinalPhase(profile: staged, now: end), "after contest no next")
        staged.hideNextInFinalPhase = false
        check(!ClockCore.isFinalPhase(profile: staged, now: stage2.date), "toggle shows next")

        let alerts = ClockCore.dueAlerts(profile: staged, previous: end.addingTimeInterval(-61),
                                         now: end.addingTimeInterval(-59), fired: [])
        check(alerts.count == 1 && alerts[0].minutes == 1, "one-minute end reminder")
        check(ClockCore.dueAlerts(profile: staged, previous: end.addingTimeInterval(-61),
                                  now: end.addingTimeInterval(-59), fired: Set([alerts[0].key])).isEmpty,
              "alerts do not repeat")

        // CTFd API sample: success + data with pos/name/score/bracket_name.
        let ctfd = #"{"success":true,"data":[{"pos":1,"name":"DemoAlpha","score":1250,"bracket_name":"Secondary"},{"pos":2,"name":"DemoBeta","score":900,"bracket_name":"Secondary"}]}"#.data(using: .utf8)!
        let ctfdResult = try ClockCore.parseScoreboard(ctfd, mode: FeedProtocol.ctfd,
                                                        teamName: "DemoBeta", category: "Secondary")
        check(ctfdResult.rank == 2 && ctfdResult.categoryRank == 2 && ctfdResult.score == 900,
              "CTFd official score and derived group ranking")
        check(ctfdResult.categoryRankDerived, "CTFd group result clearly derived")
        let ctfdWithID = #"{"success":true,"data":[{"pos":1,"account_id":42,"name":"DemoAlpha","score":1250}]}"#.data(using: .utf8)!
        let idResult = try ClockCore.parseScoreboard(ctfdWithID, mode: FeedProtocol.ctfd,
                                                     teamName: "42", category: "")
        check(idResult.rank == 1 && idResult.score == 1250, "CTFd account_id matching")

        // HKCTF fixture is synthetic, not copied from a contestant or real leaderboard.
        let hk = #"{"teams":[{"team_id":"S_DEMO_ALPHA","display_name":"S_DEMO_ALPHA - Example","rank":2,"score":0,"last_solve_at":null},{"team_id":"S_DEMO_BETA","display_name":"S_DEMO_BETA - Example","rank":2,"score":0,"last_solve_at":null},{"team_id":"T_DEMO_GAMMA","display_name":"T_DEMO_GAMMA - Example","rank":1,"score":500,"last_solve_at":"2026-11-06T10:04:43.827013Z"}]}"#.data(using: .utf8)!
        let hkResult = try ClockCore.parseScoreboard(hk, mode: FeedProtocol.hkctf2026,
                                                     teamName: "S_DEMO_ALPHA", category: "Secondary")
        check(hkResult.rank == 2 && hkResult.overallRankTieCount == 2, "organizer rank and tie")
        check(hkResult.categoryRank == 1 && hkResult.categoryRankTieCount == 2,
              "derived tied group ranking")
        check(hkResult.score == 0 && hkResult.submissions.isEmpty,
              "zero is valid, no invented submission history")
        let oldHKResult = try ClockCore.parseScoreboard(hk, mode: "hkcert",
                                                        teamName: "T_DEMO_GAMMA", category: "Tertiary")
        check(oldHKResult.rank == 1 && oldHKResult.lastSolveAt != nil, "old protocol can still parse")

        let custom = #"{"teams":[{"name":"DemoAlpha","score":300,"rank":2,"category":"Secondary"},{"name":"DemoBeta","score":400,"rank":1,"category":"Open"}],"submissions":[{"team":"DemoAlpha","challenge":"Example Web","result":"correct","points":100,"timestamp":1794000000}]}"#.data(using: .utf8)!
        let customResult = try ClockCore.parseScoreboard(custom, mode: FeedProtocol.custom,
                                                         teamName: "DemoAlpha", category: "Secondary")
        check(customResult.score == 300 && customResult.submissions.count == 1, "custom JSON + submissions")
        let scoreBefore = ScoreSnapshot(rank: 17, categoryRank: 8, score: 1432.53, submissions: [], status: "已同步")
        let scoreAfter = ScoreSnapshot(rank: 15, categoryRank: 9, score: 1381.17, submissions: [], status: "已同步")
        let diff = ScoreChanges.between(scoreBefore, scoreAfter)
        check(abs((diff.score ?? 0) + 51.36) < 0.001 && diff.overallRankImprovement == 2 &&
              diff.categoryRankImprovement == -1, "dynamic score decrease and rank delta")
        check(ClockCore.achievementPoints(maxPoints: 500, solves: 1) == 500,
              "first solve full points")

        // Construct an old v1.5 serialized profile without the new key.
        var oldObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(staged)) as! [String: Any]
        oldObject.removeValue(forKey: "hideNextInFinalPhase")
        oldObject["feedMode"] = "hkcert"
        oldObject["teamName"] = "PRIVATE_LOCAL_TEST_VALUE"
        oldObject["feedURL"] = "https://ctf.example.org/api/v1/leaderboard"
        let oldData = try JSONSerialization.data(withJSONObject: oldObject)
        let migrated = try JSONDecoder().decode(ContestProfile.self, from: oldData)
        check(migrated.hideNextInFinalPhase, "old profile defaults to hiding next in final phase")
        check(migrated.feedMode == FeedProtocol.hkctf2026, "protocol migration")
        check(migrated.teamName == "PRIVATE_LOCAL_TEST_VALUE", "local team ID preserved")
        check(migrated.feedURL == "https://ctf.example.org/api/v1/leaderboard", "custom endpoint preserved")
        check(migrated.milestones.count == staged.milestones.count, "timeline preserved")
        let roundtrip = try JSONDecoder().decode(ContestProfile.self, from: JSONEncoder().encode(migrated))
        check(roundtrip.hideNextInFinalPhase && roundtrip.teamName == migrated.teamName,
              "new preference round-trip")
        let v = HUDVisibility()
        let vRoundTrip = try JSONDecoder().decode(HUDVisibility.self, from: JSONEncoder().encode(v))
        check(vRoundTrip == v, "HUD element switches persisted")
        check(HUDLayoutMode.floating.rawValue == "floating" && HUDLayoutMode.topBar.rawValue == "topBar",
              "layout mode identifier stability")
        let encodedLayout = try JSONEncoder().encode(HUDLayoutMode.topBar)
        let decodedLayout = try JSONDecoder().decode(HUDLayoutMode.self, from: encodedLayout)
        check(decodedLayout == .topBar, "top bar layout preference Codable roundtrip")
        check(abs(HUDBarSizing.barWidth(available: 1512, fraction: 0.92) - 1391.04) < 0.001,
              "default 92% top bar width")
        check(HUDBarSizing.barWidth(available: 1512, fraction: 1.6) <= 1512 * 0.98 + 0.01,
              "oversized width ratio clamped")
        check(HUDBarSizing.barWidth(available: 320, fraction: 0.7) <= 304,
              "small displays stay within visible frame")
        check(HUDBarSizing.clampedFraction(.nan) == 0.92,
              "non-finite width setting falls back safely")
        check(HUDBarSizing.compactHeight == 42, "top bar always remains 42pt high")

        // Runtime localization and automatic language selection.
        let localesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("locales", isDirectory: true)
        L10n.overrideLocalesURL = localesURL
        L10n.resetCache()
        check(HUDLanguage.resolved("system", preferredLanguages: ["zh-HK", "en-US"]) == "zh-Hant", "Hong Kong defaults to Traditional Chinese")
        check(HUDLanguage.resolved("system", preferredLanguages: ["zh-CN"]) == "zh-Hans", "Simplified Chinese auto selection")
        check(HUDLanguage.resolved("system", preferredLanguages: ["ja-JP", "en-US"]) == "ja", "Japanese auto selection")
        check(HUDLanguage.resolved("system", preferredLanguages: ["fr-FR", "en-US"]) == "en", "English preference fallback")
        check(HUDLanguage.canonical("unsupported") == "system", "invalid stored language falls back to system")
        check(L10n.tr("全场排名", choice: "en") == "Overall rank", "English HUD ranking")
        check(L10n.tr("全场排名", choice: "zh-Hant") == "全場排名", "Traditional Chinese HUD ranking")
        check(L10n.tr("全场排名", choice: "ja") == "総合順位", "Japanese HUD ranking")
        check(L10n.tr("全场排名", choice: "zh-Hans") == "全场排名", "Simplified Chinese source")
        check(L10n.format("最近提交：{{challenge}} · {{result}}", choice: "ja",
                          values: ["challenge": "Example Web", "result": "正解"]) == "直近の提出：Example Web · 正解", "Localized template keeps user data")
        check(L10n.status("已同步", choice: "en") == "Synced", "Internal score status localized on display")
        check(L10n.status("同步失败：timeout（原数据可能过时）", choice: "en").contains("Sync failed"), "localized status templates")
        check(L10n.tr("Personal Team X", choice: "ja") == "Personal Team X", "user-provided names untouched")
        check(L10n.tr("顶部横幅", choice: "en") == "Top bar", "English layout selector")
        check(L10n.tr("顶部横幅", choice: "zh-Hant") == "頂部橫幅", "Traditional Chinese layout selector")
        check(L10n.tr("顶部横幅", choice: "ja") == "トップバー", "Japanese layout selector")
        print("All v1.9 tests passed: protocols, timeline, migrations, score deltas, language selection, English/Chinese/Japanese localization.")
    }
}
