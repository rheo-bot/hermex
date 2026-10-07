import Foundation

/// A session change a Hermes host refused with its reason (#1048): a PATCH's 400 `{detail}`,
/// such as a title already in use, over 100 characters, or the canonical Bot Chat's. The
/// message is the host's own words, shown as they are.
struct HermesSessionRefusal: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Deletes a Hermes session the way #1048 decided: through `session.delete`, never REST `DELETE`,
/// so a runtime that holds the session blocks it instead of losing that work.
///
/// The host refuses (4023) while any runtime in its process holds the session, and keeps a
/// runtime after the screen that attached it leaves. So this phone's own runtimes on the session
/// (`BotTransport.attachedRuntimes`, as `session.active_list` still lists them) are closed first
/// when idle, and a busy one refuses the delete before anything is sent. A 4023 after that is a
/// runtime this phone did not attach: another app has the session open, and nothing changed.
/// The host can't say who else views a runtime this phone attached, so closing one ends it for
/// them too.
@MainActor enum HermesSessionDeletion {
    enum Outcome: Equatable {
        case deleted
        /// A reply runs, or waits on an answer, in a runtime this phone attached.
        case busyHere
        /// The host refused (4023): a runtime this phone did not attach holds the session.
        case openElsewhere
    }

    static func delete(key: String, profile: String, on wire: any BotTransport) async throws -> Outcome {
        // An older host without the live list still refuses a held session with 4023.
        let live = (try? await wire.call(.sessionActiveList))?["sessions"].list ?? []
        let attached = wire.attachedRuntimes
        let own = live.filter { $0["session_key"].text == key && attached.contains($0["id"].text ?? "") }
        if own.contains(where: { !SessionRowAttentionState.hermesStates([$0]).isEmpty }) { return .busyHere }
        for runtime in own.compactMap({ $0["id"].text }) {
            _ = try await wire.call(.sessionClose(runtime: runtime))
        }
        do {
            _ = try await wire.call(.sessionDelete(profile: profile, storedKey: key))
        } catch BotFailure.rejected(4023) {
            return .openElsewhere
        }
        return .deleted
    }

    /// What the list and the Archived screen say when the host kept the session.
    static func message(for outcome: Outcome) -> String? {
        switch outcome {
        case .deleted: return nil
        case .busyHere: return String(localized: "This session is still replying here. Stop the reply first, then delete it.")
        case .openElsewhere:
            return String(localized: "This session is open in another app, so nothing was deleted. Close it there, then try again.")
        }
    }
}
