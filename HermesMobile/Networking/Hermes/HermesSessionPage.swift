import Foundation

/// One `GET /api/sessions` page (`HermesREST.sessionList`, #1046). Its `total` is never read:
/// it counts rows the list never shows and leaves out the pinned back-fill. A row that can't be
/// read is skipped, yet still counts in `count`, so it never ends paging early. A page without
/// its `sessions` list is a failed read, not an empty Profile.
struct HermesSessionPage: Decodable, Equatable {
    let rows: [HermesSessionRow]
    /// How many rows the host sent, readable or not.
    let count: Int

    init(rows: [HermesSessionRow], count: Int? = nil) {
        self.rows = rows
        self.count = count ?? rows.count
    }

    enum CodingKeys: String, CodingKey { case sessions }

    init(from decoder: Decoder) throws {
        let slots = try decoder.container(keyedBy: CodingKeys.self).decode([Slot].self, forKey: .sessions)
        rows = slots.compactMap(\.row)
        count = slots.count
    }

    private struct Slot: Decodable {
        let row: HermesSessionRow?
        init(from decoder: Decoder) throws { row = try? HermesSessionRow(from: decoder) }
    }
}

/// One session row of a Hermes Profile's list. Every field but `id` is optional, and unknown
/// ones are ignored. A row's identity is its `_lineage_root_id`, which only a legacy
/// compression chain carries, else its `id`; it is opened and changed by `id`, that chain's tip.
struct HermesSessionRow: Decodable, Equatable {
    let id: String
    /// Changed in place by a rename this phone made (#1048), as are `pinned` and `archived`.
    var title: String?
    /// The first prompt, flattened onto one line and cut at 60 characters with `...`.
    let preview: String?
    let lastActive: Double?
    let startedAt: Double?
    var pinned: Bool?
    var archived: Bool?
    /// The host's read mark. A session no client has marked reads as read.
    let unread: Bool?
    /// Hidden from the list, as a bot's Bot Chat is; only the Archived screen shows such a row.
    let hidden: Bool?
    let model: String?
    let cwd: String?
    let messageCount: Int?
    let profile: String?
    let parentSessionID: String?
    let lineageRootID: String?

    var identity: String { lineageRootID ?? id }

    /// A bot's canonical Bot Chat (#1048): hidden, under its exact title.
    var isBotChat: Bool { hidden == true && title == HermesCall.botChatTitle }

    enum CodingKeys: String, CodingKey {
        case id, title, preview, pinned, archived, unread, hidden, model, cwd, profile
        case lastActive = "last_active", startedAt = "started_at", messageCount = "message_count"
        case parentSessionID = "parent_session_id", lineageRootID = "_lineage_root_id"
    }

    init(id: String, title: String? = nil, preview: String? = nil, lastActive: Double? = nil, startedAt: Double? = nil,
         pinned: Bool? = nil, archived: Bool? = nil, unread: Bool? = nil, hidden: Bool? = nil, model: String? = nil,
         cwd: String? = nil, messageCount: Int? = nil, profile: String? = nil, parentSessionID: String? = nil,
         lineageRootID: String? = nil) {
        self.id = id; self.title = title; self.preview = preview; self.lastActive = lastActive; self.startedAt = startedAt
        self.pinned = pinned; self.archived = archived; self.unread = unread; self.hidden = hidden; self.model = model
        self.cwd = cwd; self.messageCount = messageCount; self.profile = profile; self.parentSessionID = parentSessionID
        self.lineageRootID = lineageRootID
    }

    init(from decoder: Decoder) throws {
        let row = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = row.decodeLossyStringIfPresent(forKey: .id), !id.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A session row without an id"))
        }
        // `Date(timeIntervalSince1970:)` takes NaN and infinity and traps later, in formatting.
        let time = { (key: CodingKeys) in row.decodeLossyDoubleIfPresent(forKey: key).flatMap { $0.isFinite ? $0 : nil } }
        let root = row.decodeLossyStringIfPresent(forKey: .lineageRootID)
        self.init(
            id: id, title: row.decodeLossyStringIfPresent(forKey: .title), preview: row.decodeLossyStringIfPresent(forKey: .preview),
            lastActive: time(.lastActive), startedAt: time(.startedAt), pinned: row.decodeLossyBoolIfPresent(forKey: .pinned),
            archived: row.decodeLossyBoolIfPresent(forKey: .archived), unread: row.decodeLossyBoolIfPresent(forKey: .unread),
            hidden: row.decodeLossyBoolIfPresent(forKey: .hidden),
            model: row.decodeLossyStringIfPresent(forKey: .model), cwd: row.decodeLossyStringIfPresent(forKey: .cwd),
            messageCount: row.decodeLossyIntIfPresent(forKey: .messageCount), profile: row.decodeLossyStringIfPresent(forKey: .profile),
            parentSessionID: row.decodeLossyStringIfPresent(forKey: .parentSessionID),
            lineageRootID: root?.isEmpty == false ? root : nil
        )
    }

    /// The row as the session list shows it, in `profile` unless the row names its own. Its
    /// title and preview drop the reference lines a Hermex send appends
    /// (`MessageAttachment.hermesTitle`); the host keeps its own text. A Bot Chat names its bot's
    /// Profile, as "Bot Chat · <Profile>", since every bot's has the same title.
    func summary(in profile: String) -> SessionSummary {
        let profile = self.profile.flatMap { $0.isEmpty ? nil : $0 } ?? profile
        return SessionSummary(
            sessionId: id, title: isBotChat ? String(localized: "Bot Chat · \(profile)") : MessageAttachment.hermesTitle(title),
            workspace: cwd, model: model, messageCount: messageCount, createdAt: startedAt, lastMessageAt: lastActive,
            pinned: pinned, archived: archived, profile: profile, parentSessionId: parentSessionID,
            hermes: SessionSummary.Hermes(lineageRoot: identity, unread: unread == true,
                                          preview: MessageAttachment.hermesTitle(preview))
        )
    }
}

/// A Hermes Profile's list across the pages read so far (#1046). Every page repeats each pinned
/// row its own rows missed, archived ones included, and rows shift between pages as sessions
/// move, so a row is kept once, by identity, and an archived one never. The Archived screen's
/// pages (#1048) keep only archived rows, since their back-fill brings unarchived pinned ones.
struct HermesSessionPages: Equatable {
    /// True for the Archived screen's pages.
    let archived: Bool
    private(set) var rows: [HermesSessionRow] = []
    /// Where the next page starts. A row that leaves moves the host's later rows up one, so it
    /// moves back one too; for a back-filled pinned row that only re-reads a row.
    private(set) var nextOffset = 0
    /// False once a page shows the list's end.
    private(set) var hasMore = true
    private var identities: Set<String> = []

    init(archived: Bool = false) {
        self.archived = archived
    }

    /// Adds the page read at `nextOffset`. One shorter than a full page ends the list. The
    /// back-filled pinned rows can't be told from the page's own, so a page at least that long
    /// reads on, unless it brought no new row, which also ends a list whose pinned rows alone
    /// would fill every page.
    mutating func append(_ page: HermesSessionPage) {
        var added = 0
        for row in page.rows where (row.archived == true) == archived && identities.insert(row.identity).inserted {
            rows.append(row)
            added += 1
        }
        nextOffset += HermesREST.sessionPageSize
        hasMore = page.count >= HermesREST.sessionPageSize && added > 0
    }

    /// The row this phone changed, opened and changed by `id` (#1048).
    func row(_ id: String) -> HermesSessionRow? { rows.first { $0.id == id } }

    /// Shows a change this phone wrote before the next read does: a pin or title in place, and
    /// an archive or restore as the row leaving these pages. Returns the row as it was and where
    /// it stood, so a refused write can put it back.
    mutating func apply(_ change: HermesSessionChange, to id: String) -> (row: HermesSessionRow, index: Int)? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let before = rows[index]
        switch change {
        case .pinned(let pinned): rows[index].pinned = pinned
        case .title(let title): rows[index].title = title
        case .archived(let archived) where archived != self.archived: remove(id)
        case .archived, .unread: break
        }
        return (before, index)
    }

    /// Drops the row with `id`, as a delete the host confirmed does.
    mutating func remove(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        identities.remove(rows.remove(at: index).identity)
        nextOffset = max(nextOffset - 1, 0)
    }

    /// Puts `row` back as it was, where it stood: in place of the row with its identity, else at
    /// `index`.
    mutating func restore(_ row: HermesSessionRow, at index: Int) {
        if let current = rows.firstIndex(where: { $0.identity == row.identity }) { rows[current] = row; return }
        rows.insert(row, at: min(index, rows.count))
        identities.insert(row.identity)
        nextOffset += 1
    }
}

extension SessionRowAttentionState {
    /// A Hermes list's row states from one `session.active_list` reply (#1046), by the stored
    /// session each runtime runs (`session_key`). `waiting` (an open approval, question or other
    /// request) reads as Input, since the item can't say which; `starting`, `working` and
    /// `streaming` as Working; idle, `resuming` and unknown states as nothing. Of several runtimes
    /// on one session, Input wins. The list's `is_active` is a 300-second guess and is never read.
    static func hermesStates(_ items: [BotJSON]) -> [String: SessionRowAttentionState] {
        var states: [String: SessionRowAttentionState] = [:]
        for item in items {
            guard let key = item["session_key"].text, !key.isEmpty,
                  let status = BotLiveStatus(wire: item["status"].text) else { continue }
            if status == .waiting || states[key] == nil { states[key] = status == .waiting ? .input : .working }
        }
        return states
    }
}
