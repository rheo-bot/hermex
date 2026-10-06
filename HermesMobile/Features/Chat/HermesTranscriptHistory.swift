import Foundation

/// A Hermes session's settled history as its REST transcript pages bring it (#1047): display
/// rows in the host's order, the newest page first, older pages put in front. A row's `id` is
/// the host's `messages.id`. It names the row on every page, but ids do not follow display
/// order (a compaction re-inserts the session's first rows under new ids), so pages join by
/// position and repeat rows drop by id. `offset` counts display rows back from the newest, so
/// rows added since a page was read shift the next one, which the id check absorbs.
struct HermesTranscriptHistory: Equatable {
    private(set) var rows: [BotJSON] = []
    /// Earlier rows remain on the host: the last page read was a full one.
    private(set) var hasOlder = false
    private var ids: Set<Int> = []

    /// Where the next older page starts: the display rows held, counted from the newest.
    var nextOffset: Int { rows.count }

    /// Takes the newest page (offset 0). A short one is the whole session. A full one replaces
    /// the rows held from the first row they share, which also drops rows the host stopped
    /// showing there, and keeps the older ones; sharing none, it leaves a gap, so the history
    /// starts again from it.
    mutating func mergeNewest(_ page: [BotJSON]) {
        let fresh = page.filter { Self.id($0) != nil }
        let freshIDs = Set(fresh.compactMap(Self.id))
        if page.count >= HermesREST.transcriptPageSize,
           let shared = rows.firstIndex(where: { Self.id($0).map(freshIDs.contains) == true }) {
            replace(with: rows[..<shared].filter { Self.id($0).map(freshIDs.contains) == false } + fresh)
        } else {
            replace(with: fresh)
            hasOlder = page.count >= HermesREST.transcriptPageSize
        }
    }

    /// Puts the page read at `nextOffset` in front, without the rows already held. Returns
    /// whether it added any. A short page reached the first row; a full one that added
    /// nothing ends paging too, so the same page is never asked for again.
    @discardableResult
    mutating func prependOlder(_ page: [BotJSON]) -> Bool {
        var seen = ids
        let older = page.filter { row in Self.id(row).map { seen.insert($0).inserted } == true }
        replace(with: older + rows)
        hasOlder = page.count >= HermesREST.transcriptPageSize && !older.isEmpty
        return !older.isEmpty
    }

    private mutating func replace(with rows: [BotJSON]) {
        self.rows = rows
        ids = Set(rows.compactMap(Self.id))
    }

    static func id(_ row: BotJSON) -> Int? { row["id"].integer }
}

/// Where a compacted Hermes session's "Context compaction · Reference only" card sits (#1047):
/// right after `anchorMessageID`, the last message before the host's summary row, or above the
/// rows loaded when none precedes it. The rows before it are the compacted turns.
struct HermesCompaction: Equatable {
    let referenceText: String
    let anchorMessageID: String?
}

/// A Hermes session's REST transcript rows as the main chat shows them (#1047). Bot Chat keeps
/// `BotTranscriptProjection`, which reads `session.resume`'s snapshot rows.
///
/// A row's message id is `<stored key>/row-<id>` and its `rowID` the host's id, so a reload, a
/// turn's end and a later cache agree on identity. A `tool` row carries the full output; it joins
/// the call its assistant row declared (`tool_calls`, matched by `tool_call_id`), named by the
/// host's `tool_call_labels` when it sent any. Tool rows and reasoning settle in front of the next
/// message, as in Bot Chat. `display_kind` is open: `hidden` never shows, a steer is unwrapped,
/// `async_delegation_complete` is the delegation completion row, and any other kind, such as
/// `failed_turn`, shows its text by role. The host's `display_content`, `display_commentary` and
/// `display_reasoning` already project the `codex_*` columns, which are never read. User rows that
/// open with `[System:` are the gateway's notices and stay hidden, as `session.resume` hides them.
enum HermesTranscriptProjection {
    struct Result: Equatable {
        var messages: [ChatMessage] = []
        var toolCallGroups: [ToolCallGroup] = []
        var reasoningGroups: [ReasoningGroup] = []
        var compaction: HermesCompaction?
    }

    static func project(_ rows: [BotJSON], root: String) -> Result {
        var result = Result()
        var tools: [ToolCall] = []
        var reasoning: [String] = []
        var pendingStart: Int?
        // Each declared call's name and arguments, for the tool row that answers it.
        var calls: [String: (name: String?, args: [String: JSONValue]?)] = [:]

        func flush(anchor: String?) {
            guard let start = pendingStart else { return }
            if !tools.isEmpty {
                result.toolCallGroups.append(ToolCallGroup(id: "\(root)/row-\(start)/tools", anchorMessageID: anchor, toolCalls: tools))
            }
            if !reasoning.isEmpty {
                result.reasoningGroups.append(ReasoningGroup(id: "\(root)/row-\(start)/reasoning", anchorMessageID: anchor,
                                                             text: reasoning.joined(separator: "\n\n")))
            }
            tools = []; reasoning = []; pendingStart = nil
        }

        for row in rows {
            guard let rowID = HermesTranscriptHistory.id(row), let role = row["role"].text else { continue }
            let kind = row["display_kind"].text
            if row["_compressed_summary"].flag == true {
                // The latest summary places the card; the rows before it are the compacted turns.
                // Only the real content the host found inside it (`display_content`) is a row.
                result.compaction = HermesCompaction(referenceText: summary(row["content"].text ?? ""),
                                                     anchorMessageID: result.messages.last?.messageId)
                guard row["display_content"].text != nil else { continue }
            }
            guard kind != "hidden" else { continue }
            switch role {
            case "tool":
                pendingStart = pendingStart ?? rowID
                let call = row["tool_call_id"].text.flatMap { calls[$0] }
                tools.append(ToolCall(
                    id: "\(root)/row-\(rowID)", name: call?.name ?? row["tool_name"].text,
                    preview: BotTurnActivity.resultPreview(row["content"]), args: call?.args, isCompleted: true,
                    startedAt: row["timestamp"].number ?? 0
                ))
            case "assistant", "user":
                if role == "assistant" {
                    for call in row["tool_calls"].list ?? [] {
                        guard let id = call["id"].text ?? call["call_id"].text else { continue }
                        calls[id] = (toolName(call, labels: row["tool_call_labels"][id]), arguments(call["function"]["arguments"]))
                    }
                    let thought = row["display_reasoning"].text ?? row["reasoning"].text ?? row["reasoning_content"].text
                    if let thought, !thought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        pendingStart = pendingStart ?? rowID
                        reasoning.append(thought)
                    }
                }
                let text = Self.text(row)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      role == "assistant" || !text.drop(while: \.isWhitespace).hasPrefix("[System:") else { continue }
                let id = "\(root)/row-\(rowID)"
                flush(anchor: id)
                let isDelegationCompletion = kind == BotDelegationCompletion.displayKind
                // A steer is stored inside the out-of-band marker; unwrapped first, the trailing
                // mention note is still a suffix and is hidden as on any other user row.
                let steer = role == "user" ? ChatMessage.strippedSteerText(from: text) : nil
                result.messages.append(ChatMessage(
                    role: isDelegationCompletion ? "delegation_completion" : role,
                    content: role == "user" && !isDelegationCompletion ? BotMentions.displayText(steer ?? text) : text,
                    timestamp: row["timestamp"].number,
                    messageId: id,
                    displayKind: steer != nil ? ChatMessage.steerDisplayKind : kind,
                    displayMetadata: row["display_metadata"].argumentDictionary,
                    rowID: rowID
                ))
            default:
                continue
            }
        }
        flush(anchor: nil)
        return result
    }

    /// A row's shown text: the host's `display_content` when it sent one, else `content` (a
    /// string, or the text of a parts list), after any public commentary the host projected.
    private static func text(_ row: BotJSON) -> String {
        let body: String
        if let shown = row["display_content"].text {
            body = shown
        } else if let parts = row["content"].list {
            body = parts.compactMap { $0.text ?? $0["text"].text }.joined()
        } else {
            body = row["content"].text ?? ""
        }
        let commentary = (row["display_commentary"].list ?? []).compactMap(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let joined = commentary.joined(separator: "\n\n")
        guard !commentary.isEmpty, joined.trimmingCharacters(in: .whitespacesAndNewlines)
            != body.trimmingCharacters(in: .whitespacesAndNewlines) else { return body }
        return ([joined] + (body.isEmpty ? [] : [body])).joined(separator: "\n\n")
    }

    /// A declared call's name: its labels' text (a bridge call such as `tool_call` names the
    /// tools it ran), else the function's own name.
    private static func toolName(_ call: BotJSON, labels: BotJSON) -> String? {
        let named = (labels.list ?? []).compactMap { $0["text"].text ?? $0["name"].text }.filter { !$0.isEmpty }
        return named.isEmpty ? call["function"]["name"].text : named.joined(separator: ", ")
    }

    /// A call's arguments: a JSON string as the provider sent it, or an object.
    private static func arguments(_ value: BotJSON) -> [String: JSONValue]? {
        guard let text = value.text else { return value.argumentDictionary }
        return (try? JSONDecoder().decode(BotJSON.self, from: Data(text.utf8)))?.argumentDictionary
    }

    /// The summary a compaction handoff carries, for the card: after any prior context the host
    /// merged in front of it, without the handoff's first line (the host's instructions to the
    /// model) and its end marker.
    static func summary(_ content: String) -> String {
        var text = Substring(content)
        if let merged = text.range(of: "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]") {
            text = text[merged.upperBound...]
        }
        text = text.drop(while: \.isWhitespace)
        if ChatMarkerMessageClassifier.isContextCompactionText(String(text)) {
            text = text.firstIndex(of: "\n").map { text[$0...] } ?? ""
        }
        if let end = text.range(of: "--- END OF CONTEXT SUMMARY") { text = text[..<end.lowerBound] }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
