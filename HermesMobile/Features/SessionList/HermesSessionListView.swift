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
/// Its project rows are the host's folder-based project lanes (#1052): a pick filters the list to
/// one lane, and a row's Move to Project changes the session's working folder.
struct HermesSessionListView: View {
    /// The webui list's Projects disclosure, alone.
    private static let projectRows = SidebarSectionVisibility(
        bots: false, tasks: false, kanban: false, skills: false, memory: false, insights: false,
        activeProfile: false, projects: true
    )

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SessionRowDisplaySettings.showMessageCountKey) private var showsMessageCount = true
    @AppStorage(SessionRowDisplaySettings.showWorkspaceKey) private var showsWorkspace = true
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @AppStorage(SessionSidebarDisclosureSettings.projectsAreExpandedKey)
    private var projectsAreExpanded = SessionSidebarDisclosureSettings.defaultProjectsAreExpanded
    private let entry: HermesSessionListEntry
    @State private var viewModel: SessionListViewModel
    /// The chat a row or New Session opened.
    @State private var chat: HermesSessionChat?
    @State private var renaming: SessionSummary?
    @State private var deleting: SessionSummary?
    @State private var exported: SessionExportShareItem?
    @State private var showingArchived = false
    @State private var actionToast = ActionToastState()
    /// The project lane the list shows; nil shows every session.
    @State private var selectedProjectID: String?
    @State private var creatingProject: HermesProjectCreation?
    @State private var renamingProject: ProjectSummary?
    @State private var deletingProject: ProjectSummary?
    @State private var moving: HermesProjectMove?
    /// The Move to Project a project created from a row's Move menu still needs, asked once the
    /// sheet is gone.
    @State private var movingAfterCreation: HermesProjectMove?

    init(entry: HermesSessionListEntry) {
        self.entry = entry
        let server = entry.server
        _viewModel = State(initialValue: SessionListViewModel(server: server, hermes: HermesSessionListSource(
            connection: entry.connection, profile: entry.profile, makeWire: { BotClient(saved: $0, server: server) }
        )))
    }

    var body: some View {
        List {
            SessionSidebarUtilityRows(
                viewModel: viewModel, topPadding: 10, automatedVisibility: .showAll, sectionVisibility: Self.projectRows,
                profilesAreExpanded: .constant(false), projectsAreExpanded: $projectsAreExpanded,
                selectedProjectID: $selectedProjectID, projectPendingDeletion: $deletingProject,
                projectPendingRename: $renamingProject, openDestination: { _ in }, switchActiveProfile: { _ in },
                presentProjectCreation: { creatingProject = HermesProjectCreation(folder: "") }
            )
            SessionListRowsSection(
                viewModel: viewModel,
                sessions: viewModel.visibleSessions(searchText: "", selectedProjectID: selectedProjectID),
                emptyTitle: selectedProjectID == nil ? String(localized: "No sessions yet") : String(localized: "No sessions in this project"),
                emptyDescription: nil,
                isSearchActive: false,
                showsMessageCount: showsMessageCount,
                showsWorkspace: showsWorkspace,
                selectedSessionID: nil,
                actions: actions
            )
            if showsLoadMore { loadMoreRow }
            archivedRow
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .animation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion), value: projectsAreExpanded)
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
        .sheet(item: $creatingProject, onDismiss: {
            viewModel.clearProjectSheetError()
            moving = movingAfterCreation
            movingAfterCreation = nil
        }) { creation in
            ProjectCreationSheet(
                existingProjectCount: viewModel.projects.count, isSaving: viewModel.isCreatingProject,
                folder: ProjectFolderField(initialPath: creation.folder) { await viewModel.completeHermesFolder($0) },
                errorMessage: viewModel.projectSheetErrorMessage
            ) {
                creatingProject = nil
            } onSave: { name, color, folder in
                Task {
                    guard let saved = await viewModel.createHermesProject(named: name, color: color, folder: folder ?? "") else { return }
                    movingAfterCreation = creation.move(intoProjectNamed: name, savedOn: saved, isBusy: creation.session
                        .map { viewModel.attentionState(for: $0) != nil } ?? false)
                    creatingProject = nil
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $renamingProject, onDismiss: { viewModel.clearProjectSheetError() }) { project in
            ProjectRenameSheet(project: project, isSaving: viewModel.isRenamingProject,
                               errorMessage: viewModel.projectSheetErrorMessage) {
                renamingProject = nil
            } onSave: { name, color in
                Task { if await viewModel.rename(project, named: name, color: color) { renamingProject = nil } }
            }
            .presentationDetents([.medium])
        }
        .alert(Text(verbatim: moving?.title ?? ""), isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } }),
               presenting: moving) { move in
            Button("Cancel", role: .cancel) {}
            Button("Move") { Task { await self.move(move) } }
        } message: { move in
            Text(verbatim: move.message)
        }
        .modifier(SessionActionConfirmations(
            viewModel: viewModel, sessionPendingDeletion: $deleting, projectPendingDeletion: $deletingProject,
            deleteSession: { session in Task { await delete(session) } },
            deleteProject: { project in Task { _ = await viewModel.delete(project) } }
        ))
        .task { await viewModel.openHermes() }
        .onDisappear {
            actionToast.dismiss()
            if chat == nil { viewModel.closeHermes() } else { viewModel.pauseHermes() }
        }
        // A lane the host no longer lists (deleted here or on Desktop, or another Profile's) clears.
        .onChange(of: viewModel.projects) {
            if let selectedProjectID, !viewModel.projects.contains(where: { $0.projectId == selectedProjectID }) {
                self.selectedProjectID = nil
            }
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

    /// More pages may hold rows this list shows: any, or the selected lane's that the host
    /// named and the loaded pages lack.
    private var showsLoadMore: Bool {
        guard viewModel.hasMoreSessions else { return false }
        return selectedProjectID.map(viewModel.hermesLaneIsShort) ?? true
    }

    /// The list's end: the next page loads as it comes into view, or in a lane every page
    /// until the lane is whole, and a tap tries again after a failed one. Keyed by the lane,
    /// so picking another lane loads its pages too. A lane picked while another page was
    /// loading starts its own once that page's rows are in; a failed page changes no rows, so
    /// it never retries on its own.
    private var loadMoreRow: some View {
        Button("Load more") { Task { await loadMore() } }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .disabled(viewModel.isLoadingMoreSessions)
            .frame(maxWidth: .infinity, minHeight: 44)
            .sessionsScreenListRow()
            .onAppear { Task { await loadMore() } }
            .onChange(of: viewModel.sessions.count) {
                guard let selectedProjectID else { return }
                Task { await viewModel.fillHermesLane(selectedProjectID) }
            }
            .id(selectedProjectID)
    }

    private func loadMore() async {
        if let selectedProjectID { await viewModel.fillHermesLane(selectedProjectID) }
        else { await viewModel.loadMoreHermesSessions() }
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
    /// offers a Hermes row; Duplicate waits on a later slice of #702. Move to Project asks first,
    /// and its New Project starts on the session's folder, then asks to move it there if it
    /// was saved on another.
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
            duplicate: { _ in },
            move: { session, projectID in
                guard let project = viewModel.projects.first(where: { $0.projectId == projectID }),
                      let folder = project.hermes?.folder else { return }
                moving = HermesProjectMove(session: session, projectName: project.name ?? folder, folder: folder,
                                           isBusy: viewModel.attentionState(for: session) != nil)
            },
            createProject: { session in creatingProject = HermesProjectCreation(folder: session.workspace ?? "", session: session) },
            refreshProjects: { Task { await viewModel.openHermes() } },
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

    /// "Moved · Undo" once the host confirms; Undo moves the session back to the folder it left.
    private func move(_ move: HermesProjectMove) async {
        guard let previous = await viewModel.moveHermesSession(move.session, toFolder: move.folder) else { return }
        let message = String(localized: "Moved")
        actionToast.show(ActionToast(
            message: message, systemImage: "folder",
            accessibilityLabel: String.localizedStringWithFormat(String(localized: "%@, %@"),
                                                                 SessionRowView.displayTitle(for: move.session), message),
            actionTitle: String(localized: "Undo"),
            action: { Task { _ = await viewModel.moveHermesSession(move.session, toFolder: previous) } }
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

/// A project sheet opened for a new Hermes project (#1052), on `folder` (the session's own when
/// it came from a row's Move menu).
struct HermesProjectCreation: Identifiable {
    let id = UUID()
    let folder: String
    /// The session whose Move menu opened the sheet; nil from the list's New Project.
    var session: SessionSummary?

    /// The Move to Project that puts `session` in the project just saved on `folder`, which asks
    /// first as any other does. Nil from the list's New Project, or when the session works in
    /// `folder` itself, which makes it the project's. A session under `folder` is asked too: a
    /// project on a deeper folder may still claim it.
    func move(intoProjectNamed name: String, savedOn folder: String, isBusy: Bool) -> HermesProjectMove? {
        guard let session, session.workspace != folder else { return nil }
        return HermesProjectMove(session: session, projectName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 folder: folder, isBusy: isBusy)
    }
}

/// A Move to Project waiting on its confirmation (#1052), with copy that says what it does: Hermes
/// works in the project's folder from then on, and no file moves. A busy session moves mid-turn.
struct HermesProjectMove: Identifiable {
    let session: SessionSummary
    let projectName: String
    let folder: String
    /// A reply runs, or waits on an answer, in the session.
    let isBusy: Bool

    var id: String { session.id }
    var title: String { String(localized: "Move to \(projectName)?") }
    var message: String {
        isBusy
            ? String(localized: "Hermes will work in \(folder) from now on, including the reply that's running now. Files aren't moved.")
            : String(localized: "Hermes will work in \(folder) from now on. Files aren't moved.")
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
