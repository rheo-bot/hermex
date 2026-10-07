import XCTest
import Observation
@testable import HermesMobile

/// A Hermes session's row actions (#1048) on the scripted gateway: a real `BotClient` and
/// `HermesGateway` over `BotSocketHost`'s socket, and `HermesHostFixture` for REST, in the shapes
/// `scripts/local-hermes` answered at the 0.21.5 pin.
@MainActor final class HermesSessionActionsTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private let record = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://hermes.example")!,
                                       username: "user", password: "secret")
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "HermesSessionActionsTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        addTeardownBlock { HermesHostFixture.reset() }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: Delete

    /// A runtime this phone attached (a chat it opened and left) blocks the host's delete, so an
    /// idle one is closed first, then the stored session goes, under its Profile.
    func testDeleteClosesThisPhonesIdleRuntimeThenDeletesTheSession() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        serveList([HermesSessionRow(id: "tip", title: "Plan", profile: "default")], until: "session.delete", on: host)
        host.always("session.active_list", .init(result: .object(["sessions": .array([live("runtime", "tip", "idle")])])))
        host.always("session.close", .init(result: .object(["closed": .bool(true)])))
        host.always("session.delete", .init(result: .object(["deleted": .string("tip")])))
        try await attachChat(on: connection)
        let list = makeList(connection)
        await list.openHermes()
        let row = try XCTUnwrap(list.sessions.first)

        let deleted = await list.delete(row)

        XCTAssertTrue(deleted)
        XCTAssertEqual(writes(host, ["session.close", "session.delete"]), [
            ["session_id": .string("runtime")],
            ["session_id": .string("tip"), "profile": .string("default")]
        ])
        XCTAssertFalse(list.sessions.contains { $0.sessionId == "tip" })
        XCTAssertNil(list.actionErrorMessage)
        XCTAssertFalse(connection.attachedRuntimes.contains("runtime"), "a closed runtime is no longer this phone's")
    }

    /// A reply still running on this phone's runtime refuses the delete before anything is sent.
    func testABusyRuntimeOnThisPhoneRefusesTheDelete() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        serveList([HermesSessionRow(id: "tip", profile: "default")], on: host)
        host.always("session.active_list", .init(result: .object(["sessions": .array([live("runtime", "tip", "streaming")])])))
        try await attachChat(on: connection)
        let list = makeList(connection)
        await list.openHermes()

        let deleted = await list.delete(try XCTUnwrap(list.sessions.first))

        XCTAssertFalse(deleted)
        XCTAssertEqual(list.actionErrorMessage, "This session is still replying here. Stop the reply first, then delete it.")
        XCTAssertEqual(writes(host, ["session.close", "session.delete"]), [])
        XCTAssertEqual(list.sessions.map(\.sessionId), ["tip"])
    }

    /// A runtime this phone never attached is another app's: it is left alone, the host refuses
    /// (4023), and the row stays.
    func testASessionOpenInAnotherAppIsRefusedWithNothingChanged() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        serveList([HermesSessionRow(id: "tip", profile: "default")], on: host)
        host.always("session.active_list", .init(result: .object(["sessions": .array([live("dashboard", "tip", "idle")])])))
        host.always("session.delete", .init(error: 4023, message: "cannot delete an active session"))
        let list = makeList(connection)
        await list.openHermes()

        let deleted = await list.delete(try XCTUnwrap(list.sessions.first))

        XCTAssertFalse(deleted)
        XCTAssertEqual(list.actionErrorMessage,
                       "This session is open in another app, so nothing was deleted. Close it there, then try again.")
        XCTAssertEqual(writes(host, ["session.close", "session.delete"]), [
            ["session_id": .string("tip"), "profile": .string("default")]
        ])
        XCTAssertEqual(list.sessions.map(\.sessionId), ["tip"])
    }

    // MARK: Rename

    /// `/title`'s call names the runtime, and a refusal carries the host's own words (4022).
    func testRenamingOnTheRuntimeCarriesTheHostsRefusal() async throws {
        let host = BotSocketHost()
        let client = BotClient(http: host.connection(record))
        try await client.connect()
        let message = "Title 'Plan' is already in use by session 20261007_003046_925526"
        host.next("session.title", .init(error: 4022, message: message))

        do {
            _ = try await client.call(.sessionRename(runtime: "runtime", title: "Plan"))
            XCTFail("The host refused the title")
        } catch BotSettingFailure.rejected(let code, let refusal) {
            XCTAssertEqual(code, 4022)
            XCTAssertEqual(refusal, message)
        }
        XCTAssertEqual(writes(host, ["session.title"]), [["session_id": .string("runtime"), "title": .string("Plan")]])
    }

    /// The rename sheet keeps the host's reason and the row keeps its title; a title the host
    /// takes is shown as the host cleaned it.
    func testARefusedRenameStaysInTheSheetAndATakenOneShowsTheHostsTitle() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        let detail = "Title 'Plan' is already in use by session 20261007_003046_925526"
        var refuses = true
        serveList([HermesSessionRow(id: "tip", title: "Draft", profile: "default")], on: host) { request in
            guard request.httpMethod == "PATCH" else { return nil }
            return refuses ? .json(400, .object(["detail": .string(detail)]))
                : .json(200, .object(["ok": .bool(true), "title": .string("Probe B two")]))
        }
        let list = makeList(connection)
        await list.openHermes()
        let row = try XCTUnwrap(list.sessions.first)

        let refused = await list.rename(row, to: "Plan")
        XCTAssertFalse(refused)
        XCTAssertEqual(list.renameErrorMessage, detail)
        XCTAssertNil(list.actionErrorMessage, "no alert behind the sheet")
        XCTAssertEqual(list.sessions.first?.title, "Draft")

        refuses = false
        let renamed = await list.rename(row, to: "Probe \u{202E}B\n two")
        XCTAssertTrue(renamed)
        XCTAssertNil(list.renameErrorMessage)
        XCTAssertEqual(list.sessions.first?.title, "Probe B two")
    }

    // MARK: Pin and archive

    /// An archive shows at once and puts the row back where it stood when the host refuses.
    func testARefusedArchivePutsTheRowBackInPlace() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        let rows = [HermesSessionRow(id: "a", lastActive: 3, profile: "default"),
                    HermesSessionRow(id: "b", lastActive: 2, profile: "default"),
                    HermesSessionRow(id: "c", lastActive: 1, profile: "default")]
        serveList(rows, on: host) { $0.httpMethod == "PATCH" ? .park : nil }
        let parked = expectation(description: "archive parked")
        HermesHostFixture.onPark = { parked.fulfill() }
        let list = makeList(connection)
        await list.openHermes()
        let row = try XCTUnwrap(list.sessions.first { $0.sessionId == "b" })

        let archive = Task { await list.archive(row) }
        await fulfillment(of: [parked], timeout: 5)
        XCTAssertEqual(list.sessions.map(\.sessionId), ["a", "c"], "the row leaves before the host answers")
        HermesHostFixture.releaseParked(.json(500, .object(["detail": .string("database is locked")])))
        let archived = await archive.value

        XCTAssertFalse(archived)
        XCTAssertEqual(list.sessions.map(\.sessionId), ["a", "b", "c"])
        XCTAssertNotNil(list.actionErrorMessage)
    }

    // MARK: Archived screen

    /// The Archived page keeps only archived rows: a hidden Bot Chat is listed under its bot's
    /// Profile, and the non-archived pinned row the host back-fills is dropped. Restoring the Bot
    /// Chat writes `archived: false` under its Profile.
    func testTheArchivedScreenListsABotChatDropsTheBackFilledPinAndRestores() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        var patches: [BotJSON] = []
        let page = BotJSON.object(["sessions": .array([
            .object(["id": .string("old"), "title": .string("Old plan"), "archived": .bool(true), "hidden": .number(0)]),
            .object(["id": .string("bot"), "title": .string("Bot Chat"), "archived": .bool(true), "hidden": .number(1)]),
            .object(["id": .string("pin"), "title": .string("Pinned"), "pinned": .bool(true), "archived": .bool(false)])
        ])])
        _ = HermesHostFixture.configuration { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/sessions"): return .json(200, page)
            case ("PATCH", "/api/sessions/bot"?):
                patches.append(Self.body(request))
                return .json(200, .object(["ok": .bool(true), "title": .string("Bot Chat"), "archived": .bool(false)]))
            default: return nil
            }
        }
        let archive = ArchivedSessionsViewModel(server: server, hermes: HermesArchiveSource(
            connection: record, profile: "research", makeWire: { _ in BotClient(http: connection) }, preferences: defaults
        ))

        await archive.load()

        XCTAssertEqual(archive.sessions.map(\.sessionId), ["old", "bot"])
        XCTAssertEqual(archive.sessions.map(\.title), ["Old plan", "Bot Chat · research"])
        let read = try XCTUnwrap(HermesHostFixture.requests.first { $0.url?.path == "/api/sessions" }?.url)
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: read, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["archived"], "only")
        XCTAssertEqual(query["profile"], "research")

        let restored = await archive.unarchive(try XCTUnwrap(archive.sessions.last))
        XCTAssertTrue(restored)
        XCTAssertEqual(patches, [.object(["archived": .bool(false), "profile": .string("research")])])
        XCTAssertEqual(archive.sessions.map(\.sessionId), ["old"])
    }

    // MARK: Export

    /// Export as JSON writes the host's export to a file named after the row's title.
    func testExportWritesTheHostsJSONNamedAfterTheTitle() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        let export = BotJSON.object(["id": .string("tip"), "messages": .array([.object(["role": .string("user")])])])
        serveList([HermesSessionRow(id: "tip", title: "Plan the launch", profile: "default")], on: host) { request in
            request.url?.path == "/api/sessions/tip/export" ? .json(200, export) : nil
        }
        let list = makeList(connection)
        await list.openHermes()

        let exported = await list.export(try XCTUnwrap(list.sessions.first), format: .json)
        let file = try XCTUnwrap(exported)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        XCTAssertEqual(file.lastPathComponent, "Plan the launch.json")
        XCTAssertEqual(try JSONDecoder().decode(BotJSON.self, from: Data(contentsOf: file)), export)
        let request = try XCTUnwrap(HermesHostFixture.requests.first { $0.url?.path == "/api/sessions/tip/export" })
        XCTAssertEqual(request.url?.query, "profile=default")
    }

    // MARK: Fixtures

    private func makeList(_ connection: HermesConnection) -> SessionListViewModel {
        SessionListViewModel(server: server, unreadStore: SessionUnreadStore(defaults: defaults), hermes: HermesSessionListSource(
            connection: record, profile: "default", makeWire: { _ in BotClient(http: connection) }, preferences: defaults,
            changeDebounce: .zero, statusPollInterval: .seconds(3600), reconnectDelays: [.seconds(3600)]
        ))
    }

    /// Answers the list's page with `rows` (none once `method` was sent, when named), and any
    /// other request with `answer`, else the host's ordinary reply.
    private func serveList(_ rows: [HermesSessionRow], until method: String? = nil, on host: BotSocketHost,
                           _ answer: @escaping (URLRequest) -> HermesHostFixture.Reply? = { _ in nil }) {
        let page = BotJSON.object(["sessions": .array(rows.map(Self.json))])
        _ = HermesHostFixture.configuration { request in
            guard request.httpMethod == "GET", request.url?.path == "/api/sessions" else { return answer(request) }
            let gone = method.map { method in host.requests.contains { $0["method"].text == method } } ?? false
            return .json(200, gone ? .object(["sessions": .array([])]) : page)
        }
    }

    /// A chat this phone opened on `tip` and left: its runtime stays on the host.
    private func attachChat(on connection: HermesConnection) async throws {
        let chat = BotClient(http: connection)
        try await chat.connect()
        _ = try await chat.call(.sessionResume(profile: "default", sessionID: "tip", omitMessages: true))
        chat.close()
    }

    /// The params of every call to one of `methods`, in order.
    private func writes(_ host: BotSocketHost, _ methods: Set<String>) -> [[String: BotJSON]] {
        host.requests.filter { methods.contains($0["method"].text ?? "") }.compactMap { $0["params"].fields }
    }

    /// One `session.active_list` item in the host's shape (`server.py` `_session_live_item`).
    private func live(_ runtime: String, _ key: String, _ status: String) -> BotJSON {
        .object(["id": .string(runtime), "session_key": .string(key), "status": .string(status), "current": .bool(false),
                 "last_active": .number(100), "started_at": .number(90), "message_count": .number(2),
                 "model": .string("m"), "preview": .string(""), "title": .string("")])
    }

    private static func json(_ row: HermesSessionRow) -> BotJSON {
        var fields: [String: BotJSON] = ["id": .string(row.id)]
        if let title = row.title { fields["title"] = .string(title) }
        if let lastActive = row.lastActive { fields["last_active"] = .number(lastActive) }
        if let profile = row.profile { fields["profile"] = .string(profile) }
        return .object(fields)
    }

    private static func body(_ request: URLRequest) -> BotJSON {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
        }
        return (try? JSONDecoder().decode(BotJSON.self, from: data)) ?? .null
    }
}
