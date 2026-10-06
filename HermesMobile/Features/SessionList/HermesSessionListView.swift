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
/// while a chat covers it, and closes when it leaves or the app goes to the background.
struct HermesSessionListView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SessionRowDisplaySettings.showMessageCountKey) private var showsMessageCount = true
    @AppStorage(SessionRowDisplaySettings.showWorkspaceKey) private var showsWorkspace = true
    private let entry: HermesSessionListEntry
    @State private var viewModel: SessionListViewModel
    /// The chat a row or New Session opened.
    @State private var chat: HermesSessionChat?

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
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
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
        .task { await viewModel.openHermes() }
        .onDisappear {
            if chat == nil { viewModel.closeHermes() } else { viewModel.pauseHermes() }
        }
        .onChange(of: chat) { old, new in
            if case .session(_, let key)? = old?.target, new?.id != old?.id { viewModel.noteHermesReturn(from: key) }
        }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .background: viewModel.closeHermes()
            // Control Center and banners (`.inactive`) keep the socket; only a closed list reopens.
            case .active where chat == nil && !viewModel.isHermesConnected: Task { await viewModel.openHermes() }
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

    /// Opening a row and Mark as Read or Unread; the actions later slices of #702 build are
    /// hidden by `SessionRowActionPolicy`.
    private var actions: SessionListRowActions {
        SessionListRowActions(
            retryLoad: { Task { await viewModel.openHermes() } },
            open: { session in
                guard let target = session.hermesTarget(listedIn: profile) else { return }
                viewModel.beginViewing(session)
                chat = HermesSessionChat(server: entry.server, connection: entry.connection, target: target)
            },
            toggleUnread: { viewModel.toggleUnread($0) },
            togglePinned: { _ in }, archive: { _ in }, delete: { _ in }, rename: { _ in }, duplicate: { _ in },
            move: { _, _ in }, createProject: { _ in }, refreshProjects: {}, export: { _, _ in }
        )
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
