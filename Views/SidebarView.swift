import SwiftUI
import ConnectOnionKit

struct SidebarViewInitialState {
    var hoveredConfigId: UUID?
    var hoveredSessionId: UUID?
    var hoveredNewChat = false
    var hoveredSettings = false
    var searchText = ""
    var editingAgentId: UUID?
    var editingAgentName = ""
    var editingSessionId: UUID?
    var editingSessionTitle = ""
    var agentPendingDeletion: GeneralAgentConfiguration?
    var sessionPendingDeletion: ChatSession?

    init() {
        hoveredConfigId = nil
        hoveredSessionId = nil
        editingAgentId = nil
        editingSessionId = nil
        agentPendingDeletion = nil
        sessionPendingDeletion = nil
    }
}

/// Manages agent and chat navigation, search, inline renaming, and deletion.
struct SidebarView: View {
    @ObservedObject var appViewModel: AppViewModel

    @State private var hoveredConfigId: UUID?
    @State private var hoveredSessionId: UUID?
    @State private var hoveredNewChat: Bool
    @State private var hoveredSearch = false
    @State private var isAttentionExpanded = false
    @State private var isSearchVisible = false
    @State private var searchMatches: Set<UUID> = []
    @FocusState private var isSearchFocused: Bool
    @State private var hoveredSettings: Bool
    @State private var searchText: String
    @State private var agentChatExpansionState = SidebarAgentChatExpansionState()
    @State private var editingAgentId: UUID?
    @State private var editingAgentName: String
    @State private var editingSessionId: UUID?
    @State private var editingSessionTitle: String
    @State private var agentPendingDeletion: GeneralAgentConfiguration?
    @State private var sessionPendingDeletion: ChatSession?
    @State private var showAllAgentIDs: Set<UUID> = []
    /// Where ↑/↓ has moved to, shown at once; the chat opens a moment later, so holding ↓
    /// doesn't connect and disconnect every chat it passes.
    @State private var keyboardSelectionID: UUID?
    @State private var keyboardCommitTask: Task<Void, Never>?
    @FocusState private var focusedAgentId: UUID?
    @FocusState private var focusedSessionId: UUID?

    init(
        appViewModel: AppViewModel,
        initialState: SidebarViewInitialState = SidebarViewInitialState()
    ) {
        self.appViewModel = appViewModel
        _hoveredConfigId = State(initialValue: initialState.hoveredConfigId)
        _hoveredSessionId = State(initialValue: initialState.hoveredSessionId)
        _hoveredNewChat = State(initialValue: initialState.hoveredNewChat)
        _hoveredSettings = State(initialValue: initialState.hoveredSettings)
        _searchText = State(initialValue: initialState.searchText)
        _editingAgentId = State(initialValue: initialState.editingAgentId)
        _editingAgentName = State(initialValue: initialState.editingAgentName)
        _editingSessionId = State(initialValue: initialState.editingSessionId)
        _editingSessionTitle = State(initialValue: initialState.editingSessionTitle)
        _agentPendingDeletion = State(initialValue: initialState.agentPendingDeletion)
        _sessionPendingDeletion = State(initialValue: initialState.sessionPendingDeletion)
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !searchQuery.isEmpty
    }

    /// While searching: agents whose name matches, and agents with a chat whose title or
    /// messages match.
    private var filteredConfigurations: [GeneralAgentConfiguration] {
        guard isSearching else {
            return appViewModel.configurations
        }
        return appViewModel.configurations.filter { config in
            agentNameMatches(config)
                || appViewModel.sessions.contains { $0.agentConfigId == config.id && searchMatches.contains($0.id) }
        }
    }

    private func agentNameMatches(_ config: GeneralAgentConfiguration) -> Bool {
        config.name.localizedStandardContains(searchQuery)
    }

    var body: some View {
        let statuses = appViewModel.sidebarStatuses
        VStack(alignment: .leading, spacing: 0) {
            newChatButton
                .padding(.top, OOSpace.small)

            if !appViewModel.configurations.isEmpty {
                searchRow
                if isSearchVisible {
                    searchField
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                attentionPanel(attentionItems(statuses))
            }

            // A firmer line than between chats: actions above, agents and their chats below.
            OOColor.inkTertiary
                .opacity(0.5)
                .frame(height: 1)
                .padding(.horizontal, OOSpace.small + OOSidebarMetrics.horizontalPadding)
                .padding(.top, OOSpace.small)
                .accessibilityHidden(true)

            agentList(statuses)
                .alert(
                    "Remove agent?",
                    isPresented: Binding(
                        get: { agentPendingDeletion != nil },
                        set: { isPresented in
                            if !isPresented {
                                agentPendingDeletion = nil
                            }
                        }
                    ),
                    presenting: agentPendingDeletion
                ) { configuration in
                    Button("Cancel", role: .cancel) {
                        agentPendingDeletion = nil
                    }
                    Button("Remove", role: .destructive) {
                        deleteAgent(configuration)
                        agentPendingDeletion = nil
                    }
                } message: { configuration in
                    Text("Removing \(configuration.name) also deletes its chats and messages.")
                }

            VStack(spacing: 2) {
                // Chats whose agent is gone sit here quietly instead of in a launch alert.
                if !appViewModel.orphanedSessions.isEmpty {
                    HiddenChatsRow(count: appViewModel.orphanedSessions.count) {
                        appViewModel.discardOrphanedSessions()
                    }
                }
                HStack {
                    settingsButton
                    Spacer(minLength: OOSpace.small)
                    addAgentButton
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .overlay(alignment: .top) {
                OOColor.hairline
                    .frame(height: 1)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(OOColor.paper)
        .onAppear {
            appViewModel.refreshAgentStatuses()
        }
        // Reruns when a message arrives too, so a new message that matches shows up.
        .task(id: "\(searchText)|\(appViewModel.messages.count)|\(appViewModel.sessions.count)") {
            await updateSearchMatches()
        }
        .onChange(of: focusedSessionId) { _, newValue in
            if editingSessionId != nil && newValue != editingSessionId {
                finishRenamingSession()
            }
        }
        .onChange(of: focusedAgentId) { _, newValue in
            if editingAgentId != nil && newValue != editingAgentId {
                finishRenamingAgent()
            }
        }
        .alert(
            "Delete chat?",
            isPresented: Binding(
                get: { sessionPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        sessionPendingDeletion = nil
                    }
                }
            ),
            presenting: sessionPendingDeletion
        ) { session in
            Button("Cancel", role: .cancel) {
                sessionPendingDeletion = nil
            }
            Button("Delete", role: .destructive) {
                appViewModel.deleteSession(session)
                sessionPendingDeletion = nil
            }
        } message: { session in
            Text("Deleting \u{201C}\(session.title)\u{201D} also deletes its messages and keeps its server record hidden on this Mac.")
        }
    }

    /// A green pencil, "New chat", and which agent it's for in grey: "New chat (my-agent)".
    private var newChatButton: some View {
        Button {
            if let configuration = preferredNewChatConfiguration {
                appViewModel.createNewSession(for: configuration)
            } else {
                showConnectAgent()
            }
        } label: {
            HStack(spacing: OOSpace.small) {
                Image(systemName: "square.and.pencil")
                    .font(OOSidebarMetrics.titleFont.weight(.semibold))
                    .foregroundStyle(OOColor.primary)
                    .frame(width: 18)
                HStack(alignment: .firstTextBaseline, spacing: OOSpace.tiny + 2) {
                    Text("New chat")
                        .font(OOSidebarMetrics.titleFont.weight(.semibold))
                        .foregroundStyle(OOColor.ink)
                        .layoutPriority(1)
                    // Same size as "New chat", only greyer and regular weight.
                    if let configuration = preferredNewChatConfiguration {
                        Text("(\(configuration.name))")
                            .font(OOSidebarMetrics.titleFont)
                            .foregroundStyle(OOColor.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, OOSidebarMetrics.horizontalPadding)
            .frame(minHeight: OOSidebarMetrics.rowHeight)
            .background(
                hoveredNewChat ? OOColor.hover : Color.clear,
                in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .command)
        .help("New chat (⌘N)")
        .onHover { hoveredNewChat = $0 }
        .accessibilityLabel(preferredNewChatConfiguration.map { "New chat with \($0.name)" } ?? "New chat")
        .padding(.horizontal, OOSpace.small)
        .padding(.bottom, OOSpace.tiny)
    }

    private var preferredNewChatConfiguration: GeneralAgentConfiguration? {
        if case .session(let sessionID) = appViewModel.selection,
           let session = appViewModel.sessions.first(where: { $0.id == sessionID }),
           let configuration = appViewModel.configuration(for: session) {
            return configuration
        }
        return appViewModel.configurations.first
    }

    /// As on iOS: a plain row that opens the field below it, and closes it again.
    /// ⌘F always opens and focuses it.
    private var searchRow: some View {
        Button(action: toggleSearch) {
            HStack(spacing: OOSpace.small) {
                Image(systemName: isSearchVisible ? "xmark" : "magnifyingglass")
                    .font(OOSidebarMetrics.titleFont)
                    .foregroundStyle(OOColor.inkSecondary)
                    .frame(width: 18)
                Text(isSearchVisible ? "Close search" : "Search")
                    .font(OOSidebarMetrics.titleFont)
                    .foregroundStyle(OOColor.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, OOSidebarMetrics.horizontalPadding)
            .frame(minHeight: OOSidebarMetrics.rowHeight)
            .background(
                hoveredSearch ? OOColor.hover : Color.clear,
                in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Search chats and messages (⌘F)")
        .onHover { hoveredSearch = $0 }
        .background {
            Button("Search", action: openSearch)
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .padding(.horizontal, OOSpace.small)
    }

    private var searchField: some View {
        HStack(spacing: OOSpace.tiny + 2) {
            Image(systemName: "magnifyingglass")
                .font(OOSidebarMetrics.metaFont)
                .foregroundStyle(OOColor.inkSecondary)
            TextField("Chats and messages", text: $searchText)
                .textFieldStyle(.plain)
                .font(OOSidebarMetrics.titleFont)
                .focused($isSearchFocused)
                .onExitCommand(perform: closeSearch)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(OOSidebarMetrics.metaFont)
                        .foregroundStyle(OOColor.inkSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .padding(.horizontal, OOSidebarMetrics.horizontalPadding)
        .frame(minHeight: OOSidebarMetrics.rowHeight)
        .background(
            OOColor.surface,
            in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
        )
        .padding(.horizontal, OOSpace.small)
        .padding(.top, OOSpace.tiny)
    }

    private func toggleSearch() {
        if isSearchVisible {
            closeSearch()
        } else {
            openSearch()
        }
    }

    private func openSearch() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isSearchVisible = true
        }
        DispatchQueue.main.async {
            isSearchFocused = true
        }
    }

    /// Closing also clears, so the full list comes back.
    private func closeSearch() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isSearchVisible = false
        }
        searchText = ""
        isSearchFocused = false
    }

    /// Chats whose title or any message contains the query, ignoring case and accents. Runs
    /// 150 ms after typing stops.
    private func updateSearchMatches() async {
        let query = searchQuery
        guard !query.isEmpty else {
            if !searchMatches.isEmpty {
                searchMatches = []
            }
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else {
            return
        }
        searchMatches = Self.sessionsMatching(query, sessions: appViewModel.sessions, messages: appViewModel.messages)
    }

    /// Chats whose title or any message contains `query`, ignoring case and accents.
    static func sessionsMatching(_ query: String, sessions: [ChatSession], messages: [ChatMessage]) -> Set<UUID> {
        var matches = Set(sessions.filter { $0.title.localizedStandardContains(query) }.map(\.id))
        for message in messages where message.content.localizedStandardContains(query) {
            matches.insert(message.sessionId)
        }
        return matches
    }

    /// Chats that need you (Approve, Not sent), most urgent first, newest first within that.
    private func attentionItems(_ statuses: [UUID: SidebarChatStatus]) -> [(session: ChatSession, status: SidebarChatStatus)] {
        appViewModel.sessions
            .compactMap { session -> (session: ChatSession, status: SidebarChatStatus)? in
                guard let status = statuses[session.id], status.needsYou else {
                    return nil
                }
                return (session, status)
            }
            .sorted { ($0.status, $1.session.updatedAt) < ($1.status, $0.session.updatedAt) }
    }

    /// As on iOS: one chat, the amber line opens it; several, it drops down to list them,
    /// inside the same amber panel.
    @ViewBuilder
    private func attentionPanel(_ items: [(session: ChatSession, status: SidebarChatStatus)]) -> some View {
        if let summary = SidebarAttention.summary(items.map(\.status)) {
            let listsChats = items.count > 1
            VStack(spacing: 0) {
                Button {
                    if listsChats {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isAttentionExpanded.toggle()
                        }
                    } else if let item = items.first {
                        appViewModel.selectHistoricalSession(item.session.id)
                    }
                } label: {
                    OOSidebarAttentionLine(
                        summary,
                        isExpanded: listsChats ? isAttentionExpanded : nil,
                        drawsBackground: false
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint(listsChats ? "Lists the chats" : "Opens the chat")
                // Always there and clipped: on close the chats slide up under the line.
                VStack(spacing: 0) {
                    if listsChats && isAttentionExpanded {
                        attentionList(items)
                            .transition(.move(edge: .top))
                    }
                }
                .frame(maxWidth: .infinity)
                .clipped()
            }
            .background(
                OOColor.decisionFill,
                in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
            )
            .padding(.horizontal, OOSpace.small)
            .padding(.top, OOSpace.small)
            .onChange(of: items.count) { _, count in
                if count < 2 {
                    isAttentionExpanded = false
                }
            }
        }
    }

    private func attentionList(_ items: [(session: ChatSession, status: SidebarChatStatus)]) -> some View {
        VStack(spacing: 0) {
            OOColor.decisionLine
                .frame(height: 1)
                .accessibilityHidden(true)
            ForEach(Array(items.enumerated()), id: \.element.session.id) { index, item in
                Button {
                    appViewModel.selectHistoricalSession(item.session.id)
                } label: {
                    OOSidebarChatRow(
                        title: item.session.title,
                        lastActivity: nil,
                        status: item.status,
                        preview: appViewModel.configuration(for: item.session)?.name,
                        indent: OOSidebarMetrics.horizontalPadding + 24
                    )
                }
                .buttonStyle(.plain)
                if index < items.count - 1 {
                    OOColor.decisionLine
                        .opacity(0.6)
                        .frame(height: 1)
                        .padding(.leading, OOSidebarMetrics.horizontalPadding + 24)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.bottom, OOSpace.tiny)
    }

    private var noResultsState: some View {
        VStack(spacing: 6) {
            Text("No matches")
                .font(OOSidebarMetrics.metaFont)
                .foregroundStyle(OOColor.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

private extension SidebarView {
    static let chatsBeforeShowAll = 5

    /// Agents and their chats. A List for native scrolling and keyboard focus; rows draw their own
    /// selection (the Kit's currentTint) so the Mac matches iOS. ↑/↓ move between the listed chats.
    func agentList(_ statuses: [UUID: SidebarChatStatus]) -> some View {
        List {
            if appViewModel.configurations.isEmpty {
                emptyState
                    .sidebarRow()
            } else if filteredConfigurations.isEmpty {
                noResultsState
                    .sidebarRow()
            } else {
                ForEach(filteredConfigurations) { config in
                    agentSection(config, statuses: statuses)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
    }

    @ViewBuilder
    func agentSection(_ config: GeneralAgentConfiguration, statuses: [UUID: SidebarChatStatus]) -> some View {
        let sessions = listedSessions(for: config)
        let needsYou = sessions.contains { statuses[$0.id]?.needsYou == true }
        // Searching opens every match and lists all its chats.
        let isExpanded = isSearching || agentChatExpansionState.isExpanded(config.id)
        agentHeaderRow(config, chatCount: sessions.count, isExpanded: isExpanded, needsYou: needsYou)
            .sidebarRow(top: OOSpace.small)
        // A Claude Station has no chats to list: its row opens the Station's Work Room.
        if isExpanded && !config.isClaudeStation {
            let shown = shownSessions(for: config, from: sessions)
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, session in
                sessionRow(session, status: statuses[session.id], showsSeparator: index < shown.count - 1)
                    .sidebarRow()
            }
            if !isSearching && sessions.count > Self.chatsBeforeShowAll {
                showAllRow(config, total: sessions.count)
                    .sidebarRow()
            }
        }
    }

    /// Chats with messages, newest first; an empty chat shows only while it's the open one.
    func listedSessions(for config: GeneralAgentConfiguration) -> [ChatSession] {
        let withMessages = Set(appViewModel.visibleSessions.map(\.id))
        let selectedID = selectedSessionID
        // A search on the agent's name keeps all its chats; otherwise only the matching ones.
        let keepsAll = !isSearching || agentNameMatches(config)
        return appViewModel.sessions
            .filter { $0.agentConfigId == config.id && ($0.id == selectedID || withMessages.contains($0.id)) }
            .filter { keepsAll || searchMatches.contains($0.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func shownSessions(for config: GeneralAgentConfiguration, from sessions: [ChatSession]) -> [ChatSession] {
        isSearching || showAllAgentIDs.contains(config.id) ? sessions : Array(sessions.prefix(Self.chatsBeforeShowAll))
    }

    var selectedSessionID: UUID? {
        if case .session(let id) = appViewModel.selection {
            return id
        }
        return nil
    }

    /// The agent of the open chat; its name reads in the selection green.
    var currentAgentID: UUID? {
        guard let selectedSessionID else {
            return nil
        }
        return appViewModel.sessions.first { $0.id == selectedSessionID }?.agentConfigId
    }

    @ViewBuilder
    func agentHeaderRow(_ config: GeneralAgentConfiguration, chatCount: Int, isExpanded: Bool, needsYou: Bool) -> some View {
        if editingAgentId == config.id {
            TextField("Agent name", text: $editingAgentName)
                .focused($focusedAgentId, equals: config.id)
                .onSubmit(finishRenamingAgent)
                .onExitCommand(perform: cancelRenamingAgent)
                .modifier(SidebarRenameField(indent: OOSidebarMetrics.horizontalPadding + 16))
        } else {
            let isHovered = hoveredConfigId == config.id
            OOSidebarAgentHeader(
                name: config.name,
                isOnline: appViewModel.isAgentConnected(config),
                isExpanded: isExpanded,
                chatCount: chatCount,
                needsYou: needsYou,
                isCurrent: currentAgentID == config.id,
                onToggle: { toggleAgent(config, hasChats: chatCount > 0) },
                // As in Claude's sidebar: the chevron takes the dot's place on hover, ⋯ takes
                // the chevron's place at the end, and the count is gone (✋ stays). A Station
                // opens rather than folds, so it has no chevron.
                disclosure: config.isClaudeStation ? .hidden : .leadingOnHover,
                isHovered: isHovered,
                showsCount: false,
                isStation: config.isClaudeStation,
                actions: {
                    // ⋯ first, shown on hover; ＋ last, always there, so at rest it sits at the end.
                    // No gap between them: the 28 pt targets already space the glyphs. A Station's
                    // row already opens it, so its ＋ keeps its place but isn't shown.
                    HStack(spacing: 0) {
                        agentMenu(config)
                            .opacity(isHovered ? 1 : 0)
                            .allowsHitTesting(isHovered)
                        addChatButton(config)
                            .opacity(config.isClaudeStation ? 0 : 1)
                            .allowsHitTesting(!config.isClaudeStation)
                            .accessibilityHidden(config.isClaudeStation)
                    }
                    // The glyphs sit centred in 28 pt targets; nudge them so ＋ lines up with the
                    // right edge of the chats' times below.
                    .padding(.trailing, -6)
                }
            )
            .background(
                isHovered ? OOColor.hover : Color.clear,
                in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
            )
            .onHover { isHovering in
                if isHovering {
                    hoveredConfigId = config.id
                } else if hoveredConfigId == config.id {
                    hoveredConfigId = nil
                }
            }
            .contextMenu {
                agentMenuItems(config)
            }
            .task {
                appViewModel.refreshAgentStatus(for: config)
            }
        }
    }

    func addChatButton(_ config: GeneralAgentConfiguration) -> some View {
        Button {
            startChat(with: config)
        } label: {
            Image(systemName: "plus")
                .font(OOSidebarMetrics.titleFont.weight(.medium))
                .foregroundStyle(OOColor.inkSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New chat with \(config.name)")
        .help("New chat with \(config.name)")
    }

    func agentMenu(_ config: GeneralAgentConfiguration) -> some View {
        Menu {
            agentMenuItems(config)
        } label: {
            Image(systemName: "ellipsis")
                .font(OOSidebarMetrics.titleFont.weight(.medium))
                .foregroundStyle(OOColor.inkSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Grey like ＋; a borderless menu otherwise takes the app's green tint.
        .tint(OOColor.inkSecondary)
        .fixedSize()
        .frame(width: 28, height: 28)
        .accessibilityLabel("More for \(config.name)")
        .help("More")
    }

    @ViewBuilder
    func agentMenuItems(_ config: GeneralAgentConfiguration) -> some View {
        Button(config.isClaudeStation ? "Open Station" : "New Chat") {
            if config.isClaudeStation {
                appViewModel.createNewSession(for: config)
            } else {
                startChat(with: config)
            }
        }
        Button("Rename") {
            startRenamingAgent(config)
        }
        Divider()
        Button("Remove Agent…", role: .destructive) {
            agentPendingDeletion = config
        }
    }

    @ViewBuilder
    func sessionRow(_ session: ChatSession, status: SidebarChatStatus?, showsSeparator: Bool) -> some View {
        if editingSessionId == session.id {
            TextField("Chat name", text: $editingSessionTitle)
                .focused($focusedSessionId, equals: session.id)
                .onSubmit(finishRenamingSession)
                .onExitCommand(perform: cancelRenamingSession)
                .modifier(SidebarRenameField(indent: OOSidebarMetrics.chatIndent))
        } else {
            let isSelected = highlightedSessionID == session.id
            let isHovered = hoveredSessionId == session.id
            // ⋯ on the open chat and the hovered one, where the time was. A status stays put.
            let showsMenu = (isSelected || isHovered) && status == nil
            Button {
                keyboardCommitTask?.cancel()
                keyboardSelectionID = nil
                appViewModel.selectHistoricalSession(session.id)
            } label: {
                OOSidebarChatRow(
                    title: session.title,
                    lastActivity: session.updatedAt,
                    status: status,
                    isSelected: isSelected,
                    hidesTime: showsMenu
                )
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) {
                if showsMenu {
                    sessionMenu(session)
                        .padding(.trailing, OOSpace.tiny)
                }
            }
            .background(
                isHovered && !isSelected ? OOColor.hover : Color.clear,
                in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
            )
            .overlay(alignment: .bottom) {
                if showsSeparator {
                    OOColor.hairline
                        .frame(height: 1)
                        .padding(.leading, OOSidebarMetrics.chatIndent)
                        .padding(.trailing, OOSidebarMetrics.horizontalPadding)
                        .accessibilityHidden(true)
                }
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                startRenamingSession(session)
            })
            .onHover { isHovering in
                if isHovering {
                    hoveredSessionId = session.id
                } else if hoveredSessionId == session.id {
                    hoveredSessionId = nil
                }
            }
            .contextMenu {
                sessionMenuItems(session)
            }
        }
    }

    /// "Show all (n)" opens the rest; "Show less" folds back to the first five.
    func sessionMenu(_ session: ChatSession) -> some View {
        Menu {
            sessionMenuItems(session)
        } label: {
            Image(systemName: "ellipsis")
                .font(OOSidebarMetrics.titleFont.weight(.medium))
                .foregroundStyle(OOColor.inkSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(OOColor.inkSecondary)
        .fixedSize()
        .frame(width: 28, height: 28)
        .accessibilityLabel("More for \(session.title)")
        .help("More")
    }

    @ViewBuilder
    func sessionMenuItems(_ session: ChatSession) -> some View {
        if let configuration = appViewModel.configuration(for: session) {
            Button("New Chat with \(configuration.name)") {
                startChat(with: configuration)
            }
            Divider()
        }
        Button("Rename") {
            startRenamingSession(session)
        }
        Button("Delete Chat…", role: .destructive) {
            sessionPendingDeletion = session
        }
    }

    func showAllRow(_ config: GeneralAgentConfiguration, total: Int) -> some View {
        let isShowingAll = showAllAgentIDs.contains(config.id)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isShowingAll {
                    showAllAgentIDs.remove(config.id)
                } else {
                    showAllAgentIDs.insert(config.id)
                }
            }
        } label: {
            Text(isShowingAll ? "Show less" : "Show all (\(total))")
                .font(OOSidebarMetrics.metaFont)
                .foregroundStyle(OOColor.inkSecondary)
                .padding(.leading, OOSidebarMetrics.chatIndent)
                .frame(maxWidth: .infinity, minHeight: OOSidebarMetrics.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Opens the agent, and starts a chat with it if it has none to show. A Claude Station opens
    /// its Work Room instead (its session is the pane).
    func toggleAgent(_ config: GeneralAgentConfiguration, hasChats: Bool) {
        if config.isClaudeStation {
            appViewModel.createNewSession(for: config)
        } else if hasChats {
            toggleChats(for: config.id)
        } else {
            startChat(with: config)
        }
    }

    func startChat(with config: GeneralAgentConfiguration) {
        if !agentChatExpansionState.isExpanded(config.id) {
            agentChatExpansionState.toggle(config.id)
        }
        appViewModel.createNewSession(for: config)
    }

    /// The chats ↑/↓ step through: those on screen, in order.
    var navigableSessionIDs: [UUID] {
        filteredConfigurations.flatMap { config -> [UUID] in
            guard isSearching || agentChatExpansionState.isExpanded(config.id) else {
                return []
            }
            return shownSessions(for: config, from: listedSessions(for: config)).map(\.id)
        }
    }

    func moveSelection(by step: Int) -> KeyPress.Result {
        guard editingSessionId == nil, editingAgentId == nil,
              let target = Self.chat(after: highlightedSessionID, in: navigableSessionIDs, step: step) else {
            return .ignored
        }
        keyboardSelectionID = target
        keyboardCommitTask?.cancel()
        keyboardCommitTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else {
                return
            }
            appViewModel.selectHistoricalSession(target)
            keyboardSelectionID = nil
        }
        return .handled
    }

    /// The open chat, or the one ↑/↓ has just moved to.
    var highlightedSessionID: UUID? {
        keyboardSelectionID ?? selectedSessionID
    }

    private func toggleChats(for agentID: UUID) {
        withAnimation(.easeInOut(duration: 0.15)) {
            agentChatExpansionState.toggle(agentID)
        }
    }

    private func deleteAgent(_ configuration: GeneralAgentConfiguration) {
        agentChatExpansionState.remove(configuration.id)
        appViewModel.deleteConfiguration(configuration)
    }

    private func startRenamingAgent(_ configuration: GeneralAgentConfiguration) {
        editingAgentId = configuration.id
        editingAgentName = configuration.name
        DispatchQueue.main.async {
            focusedAgentId = configuration.id
        }
    }

    private func finishRenamingAgent() {
        guard let configurationId = editingAgentId,
              let configuration = appViewModel.configurations.first(where: { $0.id == configurationId }) else {
            cancelRenamingAgent()
            return
        }

        appViewModel.renameAgent(configuration, to: editingAgentName)
        editingAgentId = nil
        editingAgentName = ""
        focusedAgentId = nil
    }

    private func cancelRenamingAgent() {
        editingAgentId = nil
        editingAgentName = ""
        focusedAgentId = nil
    }

    private func startRenamingSession(_ session: ChatSession) {
        editingSessionId = session.id
        editingSessionTitle = session.title
        DispatchQueue.main.async {
            focusedSessionId = session.id
        }
    }

    private func finishRenamingSession() {
        guard let sessionId = editingSessionId,
              let session = appViewModel.sessions.first(where: { $0.id == sessionId }) else {
            editingSessionId = nil
            editingSessionTitle = ""
            focusedSessionId = nil
            return
        }

        appViewModel.renameSession(session, to: editingSessionTitle)
        editingSessionId = nil
        editingSessionTitle = ""
        focusedSessionId = nil
    }

    private func cancelRenamingSession() {
        editingSessionId = nil
        editingSessionTitle = ""
        focusedSessionId = nil
    }

    private var settingsButton: some View {
        Button {
            appViewModel.previousSelection = appViewModel.selection
            appViewModel.selection = .settings
        } label: {
            Label("Settings", systemImage: "gearshape")
                .font(OOSidebarMetrics.titleFont.weight(.medium))
                .foregroundStyle(OOColor.ink)
                .padding(.horizontal, OOSidebarMetrics.horizontalPadding)
                .frame(minHeight: 28)
                .background(
                    appViewModel.selection == .settings || hoveredSettings ? OOColor.hover : Color.clear,
                    in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredSettings = isHovering
        }
    }

    /// The same green rounded button as the iOS drawer.
    private var addAgentButton: some View {
        Button(action: showConnectAgent) {
            Label("Add agent", systemImage: "plus")
                .font(OOSidebarMetrics.titleFont.weight(.semibold))
                .foregroundStyle(OOColor.onPrimary)
                .padding(.horizontal, OOSpace.medium)
                .frame(minHeight: 28)
                .background(
                    OOColor.primary,
                    in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add agent")
    }

    private var emptyState: some View {
        VStack(spacing: OOSpace.small) {
            Text("No agents yet")
                .font(OOSidebarMetrics.titleFont.weight(.semibold))
                .foregroundStyle(OOColor.ink)
            Text("Paste an address on the right to start chatting.")
                .font(OOSidebarMetrics.metaFont)
                .foregroundStyle(OOColor.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 180)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, OOSpace.large)
    }

    private func showConnectAgent() {
        if appViewModel.selection != .newConfiguration {
            appViewModel.previousSelection = appViewModel.selection
        }
        appViewModel.selection = .chooseAgent
    }
}

/// Chats that belong to an agent that's no longer added. They're hidden, not deleted, so this
/// stays a quiet grey row; the explanation and Discard live in its popover.
struct HiddenChatsRow: View {
    let count: Int
    let onDiscard: () -> Void

    @State private var isShowingDetails = false
    @State private var isConfirmingDiscard = false

    static func title(count: Int) -> String {
        count == 1 ? "1 hidden chat" : "\(count) hidden chats"
    }

    var body: some View {
        Button {
            isShowingDetails = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                Text(Self.title(count: count))
                Spacer()
                Image(systemName: "info.circle")
            }
            .font(OOSidebarMetrics.metaFont)
            .foregroundStyle(OOColor.inkSecondary)
            .padding(.horizontal, OOSidebarMetrics.horizontalPadding)
            .frame(minHeight: OOSidebarMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Chats from an agent that's no longer added")
        .popover(isPresented: $isShowingDetails, arrowEdge: .trailing) {
            details
        }
        .confirmationDialog(
            count == 1 ? "Discard 1 hidden chat?" : "Discard \(count) hidden chats?",
            isPresented: $isConfirmingDiscard
        ) {
            Button("Discard", role: .destructive, action: onDiscard)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their messages are deleted from this Mac. This can't be undone.")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hidden chats")
                .font(.headline)
            Text("These chats belong to an agent that's no longer added. Add the agent again to bring them back.")
                .font(OOSidebarMetrics.metaFont)
                .foregroundStyle(OOColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Discard…", role: .destructive) {
                    isShowingDetails = false
                    isConfirmingDiscard = true
                }
                .tint(AppPalette.error)
                Button("Keep") {
                    isShowingDetails = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

/// The inline rename field, sized and inset like the row it replaces.
private struct SidebarRenameField: ViewModifier {
    let indent: CGFloat

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(OOSidebarMetrics.titleFont)
            .padding(.leading, indent)
            .padding(.trailing, OOSidebarMetrics.horizontalPadding)
            .frame(minHeight: OOSidebarMetrics.rowHeight)
            .background(
                OOColor.surface,
                in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
            )
    }
}

private extension View {
    /// A List row with no system inset, separator or background: the row draws its own.
    func sidebarRow(top: CGFloat = 0) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: OOSpace.small, bottom: 0, trailing: OOSpace.small))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// Keyboard navigation, kept outside the private extension so tests can reach it.
extension SidebarView {
    /// The chat ↑/↓ lands on: one step from `current`, held at the ends; from nothing, the first
    /// (↓) or the last (↑). nil when there are no chats.
    static func chat(after current: UUID?, in ids: [UUID], step: Int) -> UUID? {
        guard !ids.isEmpty else {
            return nil
        }
        if let current, let index = ids.firstIndex(of: current) {
            return ids[min(max(index + step, 0), ids.count - 1)]
        }
        return step > 0 ? ids.first : ids.last
    }
}
