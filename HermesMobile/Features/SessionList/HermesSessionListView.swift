import SwiftUI

/// The Sessions list the inbox's + menu pushed on a Hermes server (#1046): the server, its saved
/// connection, and the Profile the list opens on.
struct HermesSessionListEntry: Hashable, Identifiable {
    let id = UUID()
    let server: URL
    let connection: BotConnection
    let profile: String

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A Hermes server's sessions in one Profile (#1046): the webui list's rows, live states and row
/// menu, on a `SessionListViewModel` with a Hermes backend. It is pushed onto the Hermes home's
/// stack (from the inbox's + menu until #709), so it brings no navigation container of its own,
/// and a row opens in the main chat on top of it. Its socket listens while it is on screen, rests
/// while a chat covers it, and closes when it leaves or the app goes to the background. Rows
/// rename, pin, archive (with Undo and an Archived screen), delete and export as JSON (#1048).
struct HermesSessionListView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SessionRowDisplaySettings.showMessageCountKey) private var showsMessageCount = true
    @AppStorage(SessionRowDisplaySettings.showWorkspaceKey) private var showsWorkspace = true
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    private let entry: HermesSessionListEntry
    @State private var viewModel: SessionListViewModel
    /// The chat a row or New Session opened.
    @State private var chat: HermesSessionChat?
    @State private var renaming: SessionSummary?
    @State private var deleting: SessionSummary?
    @State private var exported: SessionExportShareItem?
    @State private var showingArchived = false
    @State private var actionToast = ActionToastState()

    init(entry: HermesSessionListEntry) {
        self.entry = entry
        let server = entry.server
        _viewModel = State(initialValue: SessionListViewModel(server: server, hermes: HermesSessionListSource(
            connection: entry.connection, profile: entry.profile, makeWire: { BotClient(saved: $0, server: server) }
        )))
    }

    var body: some View {
        List {
            SessionListRowsSection(
                viewModel: viewModel,
                sessions: viewModel.visibleSessions(searchText: "", selectedProjectID: nil),
                emptyTitle: String(localized: "No sessions yet"),
                emptyDescription: nil,
                isSearchActive: false,
                showsMessageCount: showsMessageCount,
                showsWorkspace: showsWorkspace,
                selectedSessionID: nil,
                actions: actions
            )
            if viewModel.hasMoreSessions { loadMoreRow }
            archivedRow
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .overlay(alignment: .bottom) {
            ActionToastView(state: actionToast)
                .frame(maxWidth: 420)
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
        }
        .refreshable { await viewModel.openHermes() }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { profileMenu }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Session", systemImage: "square.and.pencil") {
                    chat = HermesSessionChat(server: entry.server, connection: entry.connection, target: .new(profile: profile))
                }
            }
        }
        // Keyed by the chat, so a Profile picked in an empty chat replaces its screen (#1015).
        .navigationDestination(item: $chat) { chat in
            ChatView(hermesSession: chat) { self.chat = $0 }.id(chat.id)
        }
        .navigationDestination(isPresented: $showingArchived) {
            ArchivedSessionsView(server: entry.server, hermes: .saved(entry.connection, server: entry.server, profile: profile))
        }
        .sheet(item: $renaming, onDismiss: { viewModel.clearRenameError() }) { session in
            SessionRenameSheet(initialTitle: SessionRowView.displayTitle(for: session), isSaving: viewModel.isRenamingSession,
                               errorMessage: viewModel.renameErrorMessage) {
                renaming = nil
            } onSave: { title in
                Task { if await rename(session, to: title) { renaming = nil } }
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $exported) { item in
            SessionExportShareSheet(fileURL: item.fileURL)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
                // Each export has its own temp directory (`SessionListViewModel.export`).
                .onDisappear { try? FileManager.default.removeItem(at: item.fileURL.deletingLastPathComponent()) }
        }
        .modifier(SessionActionConfirmations(
            viewModel: viewModel, sessionPendingDeletion: $deleting, projectPendingDeletion: .constant(nil),
            deleteSession: { session in Task { await delete(session) } }, deleteProject: { _ in }
        ))
        .task { await viewModel.openHermes() }
        .onDisappear {
            actionToast.dismiss()
            if chat == nil { viewModel.closeHermes() } else { viewModel.pauseHermes() }
        }
        .onChange(of: chat) { old, new in
            if case .session(_, let key)? = old?.target, new?.id != old?.id { viewModel.noteHermesReturn(from: key) }
        }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .background: viewModel.closeHermes()
            // Control Center and banners (`.inactive`) keep the socket; only a closed list reopens.
            case .active where chat == nil && !showingArchived && !viewModel.isHermesConnected:
                Task { await viewModel.openHermes() }
            default: break
            }
        }
    }

    private var profile: String { viewModel.hermesProfile ?? entry.profile }

    /// The Profile whose sessions are listed. Picking another lists it and makes it the
    /// server's pick, which the composer's Profile chip shares (#1015).
    private var profileMenu: some View {
        Menu {
            Picker("Profile", selection: Binding(get: { profile }, set: { picked in
                Task { await viewModel.selectHermesProfile(picked) }
            })) {
                ForEach(viewModel.hermesProfiles.isEmpty ? [profile] : viewModel.hermesProfiles, id: \.self) {
                    Text(verbatim: $0).tag($0)
                }
            }
        } label: {
            // A Profile name is the user's own text, never a catalog key.
            Text(verbatim: profile).lineLimit(1)
                .accessibilityLabel(Text("Profile: \(profile)"))
        }
    }

    /// The list's end: the next page loads as it comes into view, and a tap tries again
    /// after a failed one.
    private var loadMoreRow: some View {
        Button("Load more") { Task { await viewModel.loadMoreHermesSessions() } }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .disabled(viewModel.isLoadingMoreSessions)
            .frame(maxWidth: .infinity, minHeight: 44)
            .sessionsScreenListRow()
            .onAppear { Task { await viewModel.loadMoreHermesSessions() } }
    }

    /// The Profile's archived sessions, hidden Bot Chats included, where they are restored.
    private var archivedRow: some View {
        Button {
            showingArchived = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "archivebox")
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text("Archived Sessions")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
        .accessibilityHint("Shows archived sessions.")
        .sessionsScreenListRow()
    }

    /// Opening a row, Mark as Read or Unread, and the row actions `SessionRowActionPolicy`
    /// offers a Hermes row; Duplicate and Move wait on later slices of #702.
    private var actions: SessionListRowActions {
        SessionListRowActions(
            retryLoad: { Task { await viewModel.openHermes() } },
            open: { session in
                guard let target = session.hermesTarget(listedIn: profile) else { return }
                viewModel.beginViewing(session)
                chat = HermesSessionChat(server: entry.server, connection: entry.connection, target: target)
            },
            toggleUnread: { viewModel.toggleUnread($0) },
            togglePinned: { session in Task { await togglePinned(session) } },
            archive: { session in Task { await archive(session) } },
            delete: { deleting = $0 },
            rename: { session in
                viewModel.clearRenameError()
                renaming = session
            },
            duplicate: { _ in }, move: { _, _ in }, createProject: { _ in }, refreshProjects: {},
            export: { session, format in
                Task { if let url = await viewModel.export(session, format: format) { exported = SessionExportShareItem(fileURL: url) } }
            }
        )
    }

    private var mutationAnimation: Animation? { SessionListMotion.sessionMutationAnimation(reduceMotion: reduceMotion) }

    private func togglePinned(_ session: SessionSummary) async {
        if await viewModel.setPinned(session.pinned != true, for: session, animation: mutationAnimation) {
            SessionHaptics.pinStateChanged(isEnabled: isHapticsEnabled)
        }
    }

    /// "Archived · Undo" once the host confirms (#865); Undo restores the row in place.
    private func archive(_ session: SessionSummary) async {
        guard await viewModel.archive(session, animation: mutationAnimation) else { return }
        SessionHaptics.archiveStateChanged(isEnabled: isHapticsEnabled)
        let message = String(localized: "Archived")
        actionToast.show(ActionToast(
            message: message, systemImage: "archivebox",
            accessibilityLabel: String.localizedStringWithFormat(String(localized: "%@, %@"),
                                                                 SessionRowView.displayTitle(for: session), message),
            actionTitle: String(localized: "Undo"),
            action: {
                Task {
                    if await viewModel.unarchive(session, animation: mutationAnimation) {
                        SessionHaptics.archiveStateChanged(isEnabled: isHapticsEnabled)
                    }
                }
            }
        ))
    }

    private func delete(_ session: SessionSummary) async {
        if await viewModel.delete(session, animation: mutationAnimation) {
            SessionHaptics.sessionDeleted(isEnabled: isHapticsEnabled)
        }
    }

    private func rename(_ session: SessionSummary, to title: String) async -> Bool {
        let renamed = await viewModel.rename(session, to: title)
        if renamed, title != session.title { SessionHaptics.sessionRenamed(isEnabled: isHapticsEnabled) }
        return renamed
    }
}

extension SessionSummary {
    /// The Hermes session this row opens (#1046): its own `id`, which on a legacy compression
    /// chain is the tip, in the row's Profile, else the listed one. Nil for a webui row.
    func hermesTarget(listedIn profile: String) -> ConversationTarget? {
        guard hermes != nil, let key = sessionId, !key.isEmpty else { return nil }
        return .session(profile: self.profile.flatMap { $0.isEmpty ? nil : $0 } ?? profile, key: key)
    }
}
