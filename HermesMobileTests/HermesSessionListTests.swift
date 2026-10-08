import XCTest
import Observation
@testable import HermesMobile

/// A Hermes server's Sessions list (#1046): `SessionListViewModel` with a Hermes backend on a
/// scripted wire whose pages, read marks and live states are the shapes the 0.21.5 pin answers.
@MainActor final class HermesSessionListTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://hermes.example")!,
                                           username: "user", password: "secret")
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "HermesSessionListTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: Paging

    func testPagesLoadInTurnAndAShortPageEndsTheList() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page(rows(0..<100)), 100: page(rows(100..<130))]
        let list = makeList(wire)

        await list.openHermes()
        XCTAssertTrue(list.hasMoreSessions)
        await list.loadMoreHermesSessions()
        await list.loadMoreHermesSessions()

        XCTAssertEqual(wire.pageReads.map(\.offset), [0, 100])
        XCTAssertEqual(list.sessions.count, 130)
        XCTAssertFalse(list.hasMoreSessions)
    }

    /// Every page repeats the pinned rows it missed, archived ones included: each shows once,
    /// pinned first, and an archived one never.
    func testPinnedBackFillShowsOnceAndArchivedPinnedRowsNever() async {
        let wire = HermesSessionListWire()
        let pinned = HermesSessionRow(id: "pinned", lastActive: 1, pinned: true)
        let archived = HermesSessionRow(id: "archived", lastActive: 2, pinned: true, archived: true)
        wire.pages["default"] = [0: page(rows(0..<100) + [pinned, archived]),
                                 100: page([pinned, archived] + rows(100..<110))]
        let list = makeList(wire)

        await list.openHermes()
        await list.loadMoreHermesSessions()

        let shown = list.visibleSessions(searchText: "", selectedProjectID: nil).compactMap(\.sessionId)
        XCTAssertEqual(shown.count, 111)
        XCTAssertEqual(shown.first, "pinned")
        XCTAssertEqual(shown.filter { $0 == "pinned" }.count, 1)
        XCTAssertFalse(shown.contains("archived"))
    }

    /// A list read that begins while "Load more" waits replaces it and reads that page itself,
    /// so the list still pages past 100 rows and "Load more" never stays disabled.
    func testAListReadDuringLoadMoreReadsThatPageItself() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page(rows(0..<100)), 100: page(rows(100..<130))]
        let list = makeList(wire)
        await list.openHermes()

        wire.holdsPages = true
        let more = Task { await list.loadMoreHermesSessions() }
        await waitUntil("next page parked") { wire.pageReads.count == 2 }
        wire.emit("sessions.changed")
        await waitUntil("list read parked") { wire.pageReads.count == 3 }
        XCTAssertTrue(list.isLoadingMoreSessions, "the next page is still on its way")
        wire.holdsPages = false
        wire.release()
        await more.value
        await waitUntil("both pages applied") { !list.isLoadingMoreSessions }

        XCTAssertEqual(wire.pageReads.map(\.offset), [0, 100, 0, 100])
        XCTAssertEqual(list.sessions.count, 130)
        XCTAssertFalse(list.hasMoreSessions)
    }

    // MARK: Rows

    func testAHermesRowOffersOnlyItsReadMark() {
        let row = HermesSessionRow(id: "a").summary(in: "default")
        XCTAssertFalse(SessionRowActionPolicy.offersMutationActions(for: row))
        XCTAssertFalse(SessionRowActionPolicy.offersExport(for: row))
        XCTAssertTrue(SessionRowActionPolicy.offersExport(for: SessionSummary(sessionId: "webui")))
    }

    /// The attachment-title rule (#1046 comment of 2026-10-05): a title or `preview` drops the
    /// reference lines a Hermex send appends, whole or cut off by the host, and falls back to
    /// the first attachment's name, or to nothing.
    func testTitlesAndPreviewsDropAttachmentReferences() {
        let image = "[The user attached an image: dashboard_20261005_120000_0123abcd_IMG_2041.jpg]"
        let examine = "[Examine it with the vision_analyze tool using image_url: /h/.hermes/images/dashboard_20261005_120000_0123abcd_IMG_2041.jpg]"
        let rows: [(text: String, shown: String?)] = [
            (image + "\n" + examine, "IMG_2041.jpg"),
            (image + " " + examine, "IMG_2041.jpg"),
            ("[The user attached an image: dashboard_20261005_120000_0123a...", nil),
            ("[The user attached an image…", nil),
            ("What breed is this?\n\n" + image + "\n" + examine, "What breed is this?"),
            ("What breed is this?  [The user attached an image: dashboard_202...", "What breed is this?"),
            ("@file:`/Users/someone/.hermes/attachments/1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed-report.pdf`", "report.pdf"),
            ("Summarize report.pdf @file:`/Users/someone/.hermes/attach...", "Summarize report.pdf"),
            ("Plan the launch for the new pricing page and draft the e...", "Plan the launch for the new pricing page and draft the e..."),
            ("Email bob@example.com about [the plan]", "Email bob@example.com about [the plan]")
        ]
        for row in rows {
            XCTAssertEqual(MessageAttachment.hermesTitle(row.text), row.shown, row.text)
        }

        let untitled = HermesSessionRow(id: "a", preview: "What breed is this?  [The user attached an image: dashb...")
        XCTAssertEqual(SessionRowView.displayTitle(for: untitled.summary(in: "default")), "What breed is this?")
        let photoOnly = HermesSessionRow(id: "b", title: "[The user attached an image…",
                                         preview: "[The user attached an image: dashboard_20261005_120000_0123a...")
        XCTAssertEqual(SessionRowView.displayTitle(for: photoOnly.summary(in: "default")), "Untitled Session")
    }

    // MARK: Unread

    /// Opening a row clears its dot at once and marks it read on the host, so Desktop agrees.
    /// A write the host refuses shows the host's mark again.
    func testOpeningARowMarksItReadAndARefusedWriteShowsItUnreadAgain() async throws {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", unread: true, profile: "default")])]
        let list = makeList(wire)
        await list.openHermes()
        let row = try XCTUnwrap(list.sessions.first)
        XCTAssertTrue(list.isUnread(row))

        wire.holdsUnread = true
        wire.unreadFails = true
        list.beginViewing(row)
        XCTAssertFalse(list.isUnread(row), "the dot clears before the host answers")
        await waitUntil("write sent") { wire.unreadWrites.count == 1 }
        XCTAssertEqual(wire.unreadWrites.first, .init(key: "a", profile: "default", unread: false))
        wire.release()
        await waitUntil("rolled back") { list.isUnread(row) }
    }

    func testMarkAsUnreadWritesTheHostsMark() async throws {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", unread: false)])]
        let list = makeList(wire)
        await list.openHermes()
        let row = try XCTUnwrap(list.sessions.first)

        list.toggleUnread(row)

        XCTAssertTrue(list.isUnread(row))
        await waitUntil("write sent") { wire.unreadWrites.count == 1 }
        XCTAssertEqual(wire.unreadWrites, [.init(key: "a", profile: "default", unread: true)])
    }

    /// Marking a row unread and opening it at once makes two marks. Sent together they could
    /// land in either order and leave the older one on the host, so the newer waits for the
    /// older to land.
    func testASessionsMarksReachTheHostInTheOrderTheyWereMade() async throws {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", unread: false)])]
        let list = makeList(wire)
        await list.openHermes()
        let row = try XCTUnwrap(list.sessions.first)

        wire.holdsUnread = true
        list.toggleUnread(row)
        await waitUntil("unread mark sent") { wire.unreadWrites.count == 1 }
        list.beginViewing(row)
        // One main-queue turn: a write started alongside the first would be on the wire now.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(wire.unreadWrites.count, 1, "the read mark waits while the unread mark is out")
        XCTAssertFalse(list.isUnread(row), "the newer mark shows at once")

        wire.holdsUnread = false
        wire.release()
        await waitUntil("read mark sent") { wire.unreadWrites.count == 2 }
        XCTAssertEqual(wire.unreadWrites.map(\.unread), [true, false])
        XCTAssertFalse(list.isUnread(row))
    }

    /// The reply you just watched finished after the chat marked the session read, so the
    /// host calls it unread: the first read after returning marks it read again, and only it.
    func testReturningFromAChatMarksItReadAgain() async throws {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", unread: false), HermesSessionRow(id: "b", unread: true)])]
        let list = makeList(wire)
        await list.openHermes()
        list.beginViewing(try XCTUnwrap(list.sessions.first { $0.sessionId == "a" }))
        list.pauseHermes()
        await waitUntil("open write") { wire.unreadWrites.count == 1 }

        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", unread: true), HermesSessionRow(id: "b", unread: true)])]
        list.noteHermesReturn(from: "a")
        await list.openHermes()
        await waitUntil("marked read again") { wire.unreadWrites.count == 2 }

        XCTAssertEqual(wire.unreadWrites.map(\.key), ["a", "a"])
        XCTAssertEqual(wire.unreadWrites.map(\.unread), [false, false])
        XCTAssertEqual(list.sessions.map { list.isUnread($0) }, [false, true])
    }

    // MARK: Live state

    /// `session.active_list` marks the listed rows by session key; idle and other Profiles'
    /// runtimes mark nothing.
    func testLiveStatesMarkListedRowsBySessionKey() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page(["a", "b", "c"].map { HermesSessionRow(id: $0) })]
        wire.active = [live("a", "streaming"), live("b", "waiting"), live("b", "working"), live("c", "idle"),
                       live("elsewhere", "working")]
        let list = makeList(wire)

        await list.openHermes()
        await waitUntil("states read") { !list.attentionStatesBySessionID.isEmpty }

        XCTAssertEqual(list.attentionStatesBySessionID, ["a": .working, "b": .input])
    }

    // MARK: Refresh

    /// A burst of `sessions.changed` reads once; events while that read is out ask for one more
    /// after it, and the list ends on the host's latest rows.
    func testSessionsChangedBurstsReadOnceAndQueueOneMore() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", title: "First")])]
        let list = makeList(wire)
        await list.openHermes()

        wire.holdsPages = true
        for _ in 0..<3 { wire.emit("sessions.changed") }
        await waitUntil("burst read parked") { wire.pageReads.count == 2 }
        for _ in 0..<3 { wire.emit("sessions.changed") }
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", title: "Latest")])]
        wire.holdsPages = false
        wire.release()
        await waitUntil("trailing read applied") { list.sessions.first?.title == "Latest" }

        XCTAssertEqual(wire.pageReads.count, 3, "open, the burst's read and exactly one more")
    }

    /// A read that began before a newer one never replaces the newer one's rows.
    func testOnlyTheNewestReadApplies() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", title: "Old")])]
        let list = makeList(wire)
        await list.openHermes()

        wire.holdsPages = true
        wire.emit("sessions.changed")
        await waitUntil("stale read parked") { wire.pageReads.count == 2 }
        wire.holdsPages = false
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", title: "New")])]
        await list.openHermes()
        XCTAssertEqual(list.sessions.first?.title, "New")

        wire.release()
        await waitUntil("stale read answered") { wire.answeredPages == 3 }
        XCTAssertEqual(list.sessions.first?.title, "New")
    }

    // MARK: Connection

    /// A lost socket reconnects quietly over the rows. A refusal the user has to act on, such
    /// as a host below the minimum release, stops there and is kept as the list's error.
    func testOnlyALostSocketReconnects() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a")])]
        let list = makeList(wire, reconnectDelays: [.zero])
        await list.openHermes()

        wire.onDisconnect?(BotFailure.transport)
        await waitUntil("reconnected") { wire.connects == 2 }
        XCTAssertNil(list.sessionLoadError)

        wire.onDisconnect?(BotFailure.outdated("0.20.0"))
        XCTAssertFalse(list.isHermesConnected)
        XCTAssertEqual(list.sessionLoadError as? BotFailure, .outdated("0.20.0"))
        XCTAssertEqual(list.sessions.map(\.sessionId), ["a"], "the rows stay")
    }

    /// A client that left the socket without a word answers every read `.stale`: the next read
    /// reconnects instead of leaving the list stale for as long as it is open.
    func testAClientThatLeftTheSocketReconnects() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", title: "Old")])]
        let list = makeList(wire, reconnectDelays: [.zero])
        await list.openHermes()

        wire.pageFailure = .stale
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", title: "New")])]
        await list.openHermes()
        await waitUntil("reconnected and read") { list.sessions.first?.title == "New" }

        XCTAssertEqual(wire.connects, 2)
    }

    // MARK: Profiles

    func testSwitchingProfileListsItsSessionsAndSavesThePick() async {
        let wire = HermesSessionListWire()
        wire.pages = ["default": [0: page([HermesSessionRow(id: "d")])], "research": [0: page([HermesSessionRow(id: "r")])]]
        let list = makeList(wire)
        await list.openHermes()
        XCTAssertEqual(list.hermesProfiles, ["default", "research"])

        await list.selectHermesProfile("research")

        XCTAssertEqual(list.hermesProfile, "research")
        XCTAssertEqual(list.sessions.map(\.sessionId), ["r"])
        XCTAssertEqual(wire.calls.last { $0.method == "session.most_recent" }?.profile, "research",
                       "the host watches the new Profile's store")
        XCTAssertEqual(defaults.string(forKey: HermesProfilePreference.key(for: server)), "research",
                       "the composer's Profile chip shares the pick")
    }

    /// A Profile deleted on the host answers 4064: the list drops it as the server's pick and
    /// moves to the Profile the host's dashboard runs.
    func testARemovedProfileMovesToTheHostsCurrentProfile() async {
        let wire = HermesSessionListWire()
        wire.removed = ["gone"]
        wire.current = "research"
        wire.pages = ["research": [0: page([HermesSessionRow(id: "r")])]]
        HermesProfilePreference.save("gone", for: server, in: defaults)
        let list = makeList(wire, profile: "gone")

        await list.openHermes()

        XCTAssertEqual(list.hermesProfile, "research")
        XCTAssertEqual(list.sessions.map(\.sessionId), ["r"])
        XCTAssertNil(list.errorMessage)
        XCTAssertNil(defaults.string(forKey: HermesProfilePreference.key(for: server)))
    }

    // MARK: Fixture

    private func makeList(_ wire: HermesSessionListWire, profile: String = "default",
                          reconnectDelays: [Duration] = [.seconds(3600)]) -> SessionListViewModel {
        SessionListViewModel(server: server, unreadStore: SessionUnreadStore(defaults: defaults), hermes: HermesSessionListSource(
            connection: connection, profile: profile, makeWire: { _ in wire }, preferences: defaults,
            changeDebounce: .zero, statusPollInterval: .seconds(3600), reconnectDelays: reconnectDelays
        ))
    }

    private func page(_ rows: [HermesSessionRow]) -> HermesSessionPage { HermesSessionPage(rows: rows) }

    /// Rows `s<n>`, newest first.
    private func rows(_ range: Range<Int>) -> [HermesSessionRow] {
        range.map { HermesSessionRow(id: "s\($0)", lastActive: Double(10_000 - $0)) }
    }

    /// One `session.active_list` item in the host's shape (`server.py` `_session_live_item`).
    private func live(_ key: String, _ status: String) -> BotJSON {
        .object(["id": .string("runtime-" + key), "session_key": .string(key), "status": .string(status),
                 "last_active": .number(100), "started_at": .number(90), "message_count": .number(2),
                 "model": .string("m"), "preview": .string(""), "title": .string(""), "current": .bool(false)])
    }

    /// Waits on observation of the list and the wire, never a clock, and fails once nothing
    /// changes for 5 s.
    private func waitUntil(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping @MainActor () -> Bool) async {
        while !condition() {
            let changed = XCTestExpectation(description: description)
            withObservationTracking { _ = condition() } onChange: { changed.fulfill() }
            guard await XCTWaiter().fulfillment(of: [changed], timeout: 5) == .completed else {
                return XCTFail("Nothing changed while waiting for: \(description)", file: file, line: line)
            }
        }
    }
}

/// A scripted Hermes host for the Sessions list: pages by Profile and offset, read marks,
/// `session.active_list`, `profiles.list` and `session.most_recent`. A test can park page reads
/// or read-mark writes, and push gateway events.
@MainActor @Observable final class HermesSessionListWire: BotTransport {
    struct UnreadWrite: Equatable { let key: String; let profile: String; let unread: Bool }

    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var pages: [String: [Int: HermesSessionPage]] = [:]
    var active: [BotJSON] = []
    var profiles = ["default", "research"]
    var current = "default"
    /// Profiles the host no longer has: 4064 over the socket, 404 over REST.
    var removed: Set<String> = []
    /// While true, page reads wait for `release()`, answering what they read when they arrived.
    var holdsPages = false
    var holdsUnread = false
    var unreadFails = false
    /// Thrown by the next page read instead of its page.
    var pageFailure: BotFailure?
    private(set) var connects = 0
    private(set) var pageReads: [(profile: String, offset: Int)] = []
    private(set) var answeredPages = 0
    private(set) var unreadWrites: [UnreadWrite] = []
    private(set) var calls: [(method: String, profile: String?)] = []
    @ObservationIgnored private var held: [CheckedContinuation<Void, Never>] = []

    func connect() async throws { connects += 1 }
    func close() {}

    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        let params = try call.params()
        calls.append((call.method, params["profile"]?.text))
        switch call.method {
        case "session.most_recent":
            if removed.contains(params["profile"]?.text ?? "") { throw BotFailure.rejected(4064) }
            return .object(["session_id": .null])
        case "session.active_list": return .object(["sessions": .array(active)])
        case "profiles.list": return .object(["profiles": .array(profiles.map { .object(["name": .string($0)]) })])
        default: throw BotFailure.unsupported
        }
    }

    func currentProfile() async throws -> String { current }

    func sessionPage(profile: String, offset: Int) async throws -> HermesSessionPage {
        pageReads.append((profile, offset))
        let reply = pages[profile]?[offset] ?? HermesSessionPage(rows: [])
        if holdsPages { await withCheckedContinuation { held.append($0) } }
        answeredPages += 1
        if let failure = pageFailure { pageFailure = nil; throw failure }
        if removed.contains(profile) { throw BotFailure.rejected(404) }
        return reply
    }

    func setSessionUnread(_ unread: Bool, key: String, profile: String) async throws {
        unreadWrites.append(UnreadWrite(key: key, profile: profile, unread: unread))
        if holdsUnread { await withCheckedContinuation { held.append($0) } }
        if unreadFails { throw BotFailure.rejected(500) }
    }

    func release() {
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }

    func emit(_ type: String) {
        onEvent?(.object(["type": .string(type), "session_id": .string("")]))
    }
}
