import Foundation
import Observation

/// Where a Hermes server's Archived screen (#1048) reads from: the server's saved connection,
/// the Profile it lists, and its client on the connection's shared socket.
struct HermesArchiveSource {
    let connection: BotConnection
    /// The Sessions list's Profile; nil (from Settings) lists the server's pick
    /// (`HermesProfilePreference`), else the Profile the host's dashboard runs.
    let profile: String?
    /// Each connect's client; tests script it.
    var makeWire: @MainActor (BotConnection) -> any BotTransport
    var preferences: UserDefaults = .standard

    /// The server's saved connection, on the socket its other screens share.
    static func saved(_ connection: BotConnection, server: URL, profile: String?) -> Self {
        Self(connection: connection, profile: profile, makeWire: { BotClient(saved: $0, server: server) })
    }
}

@MainActor
@Observable
final class ArchivedSessionsViewModel {
    private(set) var sessions: [SessionSummary] = []
    private(set) var isLoading = false
    private(set) var unarchivingSessionIDs: Set<String> = []
    private(set) var deletingSessionIDs: Set<String> = []
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?
    /// Last raw failure, exposed so the view can forward it to the shared
    /// API-error handler (401 → re-login), mirroring `SessionListViewModel`.
    private(set) var lastError: Error?
    /// More archived sessions wait on a Hermes host.
    private(set) var hasMore = false
    private(set) var isLoadingMore = false
    /// The Profile a Hermes server's screen lists, once it is known.
    private(set) var hermesProfile: String?

    private let server: URL
    private let client: APIClient
    /// Set on a Hermes server: rows come from its archived pages, and nothing reaches the webui API.
    private let hermes: HermesArchiveSource?
    @ObservationIgnored private var wire: (any BotTransport)?
    @ObservationIgnored private var pages = HermesSessionPages(archived: true)
    /// Bumped by each read, so only the newest one applies.
    @ObservationIgnored private var readSerial = 0

    var isUnarchiving: Bool {
        !unarchivingSessionIDs.isEmpty
    }

    var isHermes: Bool { hermes != nil }

    /// A Hermes server's screen holds a client on the socket.
    var isConnected: Bool { wire != nil }

    init(server: URL, client: APIClient? = nil, hermes: HermesArchiveSource? = nil) {
        self.server = server
        self.client = client ?? APIClient(baseURL: server)
        self.hermes = hermes
    }

    func load() async {
        if let hermes { return await loadHermes(hermes) }
        isLoading = true
        errorMessage = nil
        actionErrorMessage = nil
        lastError = nil

        do {
            // `include_archived=1` is required — the default response excludes
            // archived rows entirely, which made this view permanently empty
            // (issue #17). The merged response keeps the visible rows too; each
            // row carries an `archived` flag (verified against upstream routes.py
            // @312d3fab and the live server), so filter client-side.
            let response = try await client.sessions(includeArchived: true)
            sessions = (response.sessions ?? []).filter {
                Self.nonEmpty($0.sessionId) != nil && $0.archived == true
            }
        } catch {
            // A cancelled load (pull-to-refresh superseding `.task`, or the view
            // disappearing) is not a failure — don't flash an error state.
            if !Self.isCancellationError(error) {
                lastError = error
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }

    func unarchive(_ session: SessionSummary) async -> Bool {
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }
        guard !isChanging(session) else {
            return false
        }

        guard let removedSession = removeSession(withID: sessionId) else {
            return false
        }

        unarchivingSessionIDs.insert(sessionId)
        actionErrorMessage = nil
        lastError = nil
        defer {
            unarchivingSessionIDs.remove(sessionId)
        }

        if hermes != nil {
            do {
                try await restoreHermes(session, key: sessionId)
                return true
            } catch {
                restore(removedSession)
                if !Self.isCancellationError(error) { actionErrorMessage = hermesFailure(error) }
                return false
            }
        }

        do {
            let response = try await client.archiveSession(id: sessionId, archived: false)
            // Rejections (subagent / read-only CLI sessions) arrive as HTTP 400
            // and throw above; a 200 body with an `error` field is surfaced too
            // so the server's own message is always shown (issue #17). An
            // explicit `ok: false` without an `error` string is still a failure
            // (matching the `ok != false` guard used across the app) — only a
            // missing `ok` is treated as success, per tolerant decoding.
            if let error = Self.nonEmpty(response.error) {
                restore(removedSession)
                actionErrorMessage = error
                return false
            }
            if response.ok == false {
                restore(removedSession)
                actionErrorMessage = String(localized: "The server could not unarchive this session.")
                return false
            }
            return true
        } catch {
            restore(removedSession)
            if !Self.isCancellationError(error) {
                lastError = error
                actionErrorMessage = error.localizedDescription
            }
            return false
        }
    }

    func isUnarchiving(_ session: SessionSummary) -> Bool {
        guard let sessionId = session.sessionId else { return false }
        return unarchivingSessionIDs.contains(sessionId)
    }

    /// A restore or delete of `session` is in flight.
    func isChanging(_ session: SessionSummary) -> Bool {
        guard let sessionId = session.sessionId else { return false }
        return unarchivingSessionIDs.contains(sessionId) || deletingSessionIDs.contains(sessionId)
    }

    // MARK: Hermes (#1048)

    /// The Hermes session a row opens, in the row's Profile.
    func hermesChat(for session: SessionSummary) -> HermesSessionChat? {
        guard let hermes, let profile = hermesProfile,
              let target = session.hermesTarget(listedIn: profile) else { return nil }
        return HermesSessionChat(server: server, connection: hermes.connection, target: target)
    }

    /// Reads the next page of archived sessions, one at a time.
    func loadMore() async {
        guard hasMore, !isLoadingMore, let wire, let profile = hermesProfile else { return }
        let serial = readSerial
        isLoadingMore = true
        defer { if serial == readSerial { isLoadingMore = false } }
        do {
            let page = try await wire.sessionPage(profile: profile, offset: pages.nextOffset, archived: true)
            guard serial == readSerial else { return }
            var pages = self.pages
            pages.append(page)
            show(pages, profile: profile)
        } catch {
            guard serial == readSerial, !Self.isCancellationError(error) else { return }
            actionErrorMessage = hermesFailure(error)
        }
    }

    /// Deletes an archived Hermes session through `HermesSessionDeletion`, once the host
    /// confirms; a busy or held one stays, and the screen says why.
    func delete(_ session: SessionSummary) async -> Bool {
        guard let sessionId = Self.nonEmpty(session.sessionId), !isChanging(session) else { return false }
        deletingSessionIDs.insert(sessionId)
        actionErrorMessage = nil
        defer { deletingSessionIDs.remove(sessionId) }
        do {
            guard let wire, let profile = Self.nonEmpty(session.profile) ?? hermesProfile else { throw BotFailure.transport }
            let outcome = try await HermesSessionDeletion.delete(key: sessionId, profile: profile, on: wire)
            if let refusal = HermesSessionDeletion.message(for: outcome) {
                actionErrorMessage = refusal
                return false
            }
            pages.remove(sessionId)
            sessions.removeAll { $0.sessionId == sessionId }
            return true
        } catch {
            if !Self.isCancellationError(error) { actionErrorMessage = hermesFailure(error) }
            return false
        }
    }

    /// Ends this screen's calls; the shared socket stays for the server's other screens.
    func close() {
        readSerial += 1
        wire?.close()
        wire = nil
        isLoading = false
        isLoadingMore = false
    }

    /// The first page of the Profile's archived sessions, hidden Bot Chats included. A read
    /// that begins meanwhile replaces it.
    private func loadHermes(_ hermes: HermesArchiveSource) async {
        readSerial += 1
        let serial = readSerial
        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        actionErrorMessage = nil
        defer { if serial == readSerial { isLoading = false } }
        do {
            let wire = try await connectedWire(hermes)
            let profile = try await listedProfile(hermes, on: wire)
            var pages = HermesSessionPages(archived: true)
            pages.append(try await wire.sessionPage(profile: profile, offset: 0, archived: true))
            guard serial == readSerial else { return }
            show(pages, profile: profile)
        } catch {
            guard serial == readSerial, !Task.isCancelled, !Self.isCancellationError(error) else { return }
            // A client the socket dropped is replaced on the next load.
            if let failure = error as? BotFailure, [.stale, .transport].contains(failure) { wire?.close(); wire = nil }
            errorMessage = hermesFailure(error)
        }
    }

    /// This screen's client on the socket, connecting it first. A client another load
    /// connected meanwhile wins, and this one leaves.
    private func connectedWire(_ hermes: HermesArchiveSource) async throws -> any BotTransport {
        if let wire { return wire }
        let wire = hermes.makeWire(hermes.connection)
        wire.onDisconnect = { [weak self, weak wire] _ in
            guard let self, let wire, self.wire === wire else { return }
            self.wire = nil
        }
        try await wire.connect()
        if let current = self.wire {
            wire.close()
            return current
        }
        self.wire = wire
        return wire
    }

    /// The Profile the screen lists: the Sessions list's, else the server's pick while the host
    /// still lists it, else the Profile its dashboard runs. Settled once per screen.
    private func listedProfile(_ hermes: HermesArchiveSource, on wire: any BotTransport) async throws -> String {
        if let profile = hermes.profile ?? hermesProfile {
            hermesProfile = profile
            return profile
        }
        let rows = (try? await wire.call(.profilesList(includeSessions: false)))?["profiles"].list ?? []
        let current = try await wire.currentProfile()
        let profile = HermesProfilePreference.resolve(for: server, listed: rows.compactMap { $0["name"].text },
                                                      current: current, in: hermes.preferences)
        hermesProfile = profile
        return profile
    }

    private func restoreHermes(_ session: SessionSummary, key: String) async throws {
        guard let wire, let profile = Self.nonEmpty(session.profile) ?? hermesProfile else { throw BotFailure.transport }
        try await wire.updateSession(.archived(false), key: key, profile: profile)
        _ = pages.apply(.archived(false), to: key)
    }

    private func show(_ pages: HermesSessionPages, profile: String) {
        self.pages = pages
        if hasMore != pages.hasMore { hasMore = pages.hasMore }
        let rows = pages.rows.map { $0.summary(in: profile) }
        if rows != sessions { sessions = rows }
    }

    private func hermesFailure(_ error: Error) -> String {
        if let refusal = error as? HermesSessionRefusal { return refusal.message }
        if error is URLError, let hermes { return BotConnectionAdvice.message(for: error, address: hermes.connection.address) }
        return error.localizedDescription
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    private func removeSession(withID sessionId: String) -> (index: Int, session: SessionSummary)? {
        guard let index = sessions.firstIndex(where: { $0.sessionId == sessionId }) else {
            return nil
        }

        let removed = sessions.remove(at: index)
        return (index, removed)
    }

    private func restore(_ removedSession: (index: Int, session: SessionSummary)) {
        guard removedSession.session.sessionId != nil,
              !sessions.contains(where: { $0.sessionId == removedSession.session.sessionId })
        else {
            return
        }

        sessions.insert(removedSession.session, at: min(removedSession.index, sessions.count))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Mirrors `SessionListViewModel`'s cancellation check: a `CancellationError`
    /// or a (possibly `APIError.network`-wrapped) `URLError.cancelled`.
    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let underlying: Error
        if case APIError.network(let wrapped) = error {
            underlying = wrapped
        } else {
            underlying = error
        }

        guard let urlError = underlying as? URLError else { return false }
        return urlError.code == .cancelled
    }
}
