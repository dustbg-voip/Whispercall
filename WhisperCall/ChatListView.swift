import SwiftUI
import UniformTypeIdentifiers
import MobileCoreServices
import Combine
import UserNotifications

// УБИРАЕМ дублирование AppColors - теперь импортируем из CommonTypes
// УБИРАЕМ WebClientStatus - теперь импортируем из CommonTypes

// MARK: - Launch Screen View (оставляем только здесь, так как используется только в этом файле)
struct LaunchScreenView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ZStack {
            AppColors.backgroundGradient(for: colorScheme)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 32) {
                // Логотип
                ZStack {
                    Circle()
                        .fill(AppColors.primaryGradient)
                        .frame(width: 120, height: 120)
                        .shadow(color: .blue.opacity(0.3), radius: 20, y: 10)
                    
                    Image(systemName: "message.and.waveform.fill")
                        .font(.system(size: 50, weight: .bold))
                        .foregroundColor(.white)
                }
                
                // Название приложения
                VStack(spacing: 8) {
                    Text("Whisper Call")
                        .font(.system(size: 42, weight: .heavy, design: .rounded))
                        .foregroundColor(.primary)
                    
                    Text("Professional Communication Platform")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.secondary)
                }
                
                // Индикатор загрузки
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(.blue)
                    
                    Text("Connecting to server...")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 20)
                
                // Информация об авторе
                VStack(spacing: 8) {
                    Divider()
                        .frame(width: 60)
                    
                    Text("Version 3.1.1 beta")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 6) {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.blue)
                        
                        Text("Jordan Babov")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                    }
                }
            }
            .padding(40)
        }
    }
}

// MARK: - Chat List View
struct ChatListView: View {
    @StateObject private var wsService = WebSocketService.shared
    @State private var selectedTab: Int = 0
    @State private var searchText: String = ""
    @Environment(\.colorScheme) private var colorScheme
    @State private var isSearching = false
    @Namespace private var animation
    @State private var showLaunchScreen = false
    @State private var statusUpdateTimer: Timer?
    @State private var showServerChangeAlert = false
    @State private var newServerURL = ""
    
    // Данные
    @State private var importantChats: [String] = []
    @State private var archivedSessions: [String: Date] = [:]
    @State private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Computed Properties (hidden clients)
    private var activeSessions: [String] {
        let allSessions = wsService.sessions.keys
        
        // Клиент, которого нужно скрыть
        let hiddenClient = "Webvisitor_e4827"
        
        let active = allSessions.filter { sessionUUID in
            // Проверяем архив
            guard !archivedSessions.keys.contains(sessionUUID) &&
                  !wsService.archivedSessions.contains(sessionUUID) else {
                return false
            }
            
            // Получаем имя участника чата
            let messages = wsService.sessions[sessionUUID] ?? []
            let participant = messages.first { $0.from != "iOSAdmin" && $0.from != "Поддержка" }?.from ?? ""
            
            // Если это скрытый клиент - не показываем
            if participant == hiddenClient {
                print("🚫 Скрыт клиент: \(participant)")
                return false
            }
            
            return true
        }
        
        if searchText.isEmpty {
            return active.sorted { a, b in
                let aIsImportant = importantChats.contains(a)
                let bIsImportant = importantChats.contains(b)
                
                if aIsImportant && !bIsImportant { return true }
                if !aIsImportant && bIsImportant { return false }
                
                let aLast = wsService.sessions[a]?.last?.timestamp ?? 0
                let bLast = wsService.sessions[b]?.last?.timestamp ?? 0
                return aLast > bLast
            }
        }
        
        return active.filter { sessionUUID in
            let messages = wsService.sessions[sessionUUID] ?? []
            let participant = messages.first { $0.from != "iOSAdmin" && $0.from != "Поддержка" }?.from ?? ""
            let lastMessage = messages.last
            let lastMessageText = lastMessage?.message ?? lastMessage?.fileName ?? ""
            
            return participant.localizedCaseInsensitiveContains(searchText) ||
                   lastMessageText.localizedCaseInsensitiveContains(searchText) ||
                   sessionUUID.localizedCaseInsensitiveContains(searchText)
        }.sorted { a, b in
            let aLast = wsService.sessions[a]?.last?.timestamp ?? 0
            let bLast = wsService.sessions[b]?.last?.timestamp ?? 0
            return aLast > bLast
        }
    }
    
    private var archivedSessionsList: [String] {
        let archived = archivedSessions.keys.filter { wsService.sessions.keys.contains($0) }
        
        if searchText.isEmpty {
            return archived.sorted { a, b in
                let aDate = archivedSessions[a] ?? Date.distantPast
                let bDate = archivedSessions[b] ?? Date.distantPast
                return aDate > bDate
            }
        }
        
        return archived.filter { sessionUUID in
            let messages = wsService.sessions[sessionUUID] ?? []
            let participant = messages.first { $0.from != "iOSAdmin" && $0.from != "Поддержка" }?.from ?? ""
            return participant.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                if showLaunchScreen {
                    LaunchScreenView()
                        .onAppear(perform: initializeApp)
                } else {
                    AppColors.backgroundGradient(for: colorScheme)
                        .edgesIgnoringSafeArea(.all)
                    
                    VStack(spacing: 0) {
                        headerView
                        searchBarView
                        tabSelectorView
                        chatListView
                    }
                }
            }
            .navigationBarHidden(true)
            .overlay(connectionStatusOverlay, alignment: .bottom)
            .overlay(serverChangeButton, alignment: .topTrailing)
            .onAppear(perform: loadData)
            .onDisappear(perform: cleanup)
            .alert("Сменить сервер", isPresented: $showServerChangeAlert) {
                TextField("wss://новый-сервер.com/ws", text: $newServerURL)
                    .autocapitalization(.none)
                    .keyboardType(.URL)
                
                Button("Отмена", role: .cancel) { }
                
                Button("Подключиться") {
                    changeServer()
                }
            } message: {
                Text("Введите адрес нового WebSocket сервера")
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    private var serverChangeButton: some View {
        Button(action: {
            newServerURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
            showServerChangeAlert = true
        }) {
            HStack(spacing: 4) {
                Image(systemName: "server.rack")
                    .font(.system(size: 12))
                Text("Сменить сервер")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
            )
            .padding(.top, safeAreaTop() + 8)
            .padding(.trailing, 20)
        }
    }
    
    private func changeServer() {
        let trimmedURL = newServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedURL.isEmpty else { return }
        
        UserDefaults.standard.set(trimmedURL, forKey: "serverURL")
        wsService.updateServerURL(trimmedURL)
        
        wsService.sessions.removeAll()
        wsService.archivedSessions.removeAll()
        archivedSessions.removeAll()
        importantChats.removeAll()
        
        withAnimation {
            showLaunchScreen = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showLaunchScreen = false
            }
        }
    }
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Чаты")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                
                HStack(spacing: 6) {
                    Circle()
                        .fill(wsService.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    
                    Text(wsService.isConnected ? "Подключено" : "Отключено")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let serverURL = UserDefaults.standard.string(forKey: "serverURL") {
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(serverURL.replacingOccurrences(of: "wss://", with: ""))
                            .font(.caption)
                            .foregroundColor(.blue)
                            .lineLimit(1)
                    }
                }
            }
            
            Spacer()
            
            VStack(spacing: 2) {
                Text("\(activeSessions.count)")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.primary)
                
                Text("чатов")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, safeAreaTop() + 40)
        .padding(.bottom, 12)
    }
    
    private var searchBarView: some View {
        HStack {
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                
                TextField("Поиск", text: $searchText)
                    .font(.system(size: 16))
                
                if !searchText.isEmpty {
                    Button {
                        withAnimation { searchText = "" }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
            )
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 8)
    }
    
    private var tabSelectorView: some View {
        HStack(spacing: 0) {
            ForEach([("Активные", 0), ("Архив", 1)], id: \.1) { title, index in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selectedTab = index
                    }
                } label: {
                    VStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 15, weight: selectedTab == index ? .semibold : .medium))
                            .foregroundColor(selectedTab == index ? .primary : .secondary)
                        
                        if selectedTab == index {
                            Capsule()
                                .fill(Color.blue)
                                .frame(height: 2)
                                .matchedGeometryEffect(id: "tab", in: animation)
                        } else {
                            Capsule()
                                .fill(Color.clear)
                                .frame(height: 2)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
    
    private var chatListView: some View {
        let sessions = selectedTab == 0 ? activeSessions : archivedSessionsList
        
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 12) {
                ForEach(sessions, id: \.self) { sessionUUID in
                    if selectedTab == 0 {
                        NavigationLink {
                            ModernChatDetailView(sessionUUID: sessionUUID)
                                .navigationBarBackButtonHidden(true)
                        } label: {
                            ChatRowView(
                                sessionUUID: sessionUUID,
                                wsService: wsService,
                                isArchived: false,
                                isImportant: importantChats.contains(sessionUUID),
                                archiveDate: nil,
                                colorScheme: colorScheme
                            )
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                archiveSession(sessionUUID: sessionUUID)
                            } label: {
                                Label("Архив", systemImage: "archivebox")
                            }
                            .tint(.orange)
                            
                            Button {
                                toggleImportantChat(sessionUUID: sessionUUID)
                            } label: {
                                Label(importantChats.contains(sessionUUID) ? "Убрать" : "Важно",
                                      systemImage: importantChats.contains(sessionUUID) ? "star.slash" : "star")
                            }
                            .tint(importantChats.contains(sessionUUID) ? .gray : .yellow)
                        }
                    } else {
                        NavigationLink {
                            ModernChatDetailView(sessionUUID: sessionUUID)
                                .navigationBarBackButtonHidden(true)
                        } label: {
                            ChatRowView(
                                sessionUUID: sessionUUID,
                                wsService: wsService,
                                isArchived: true,
                                isImportant: false,
                                archiveDate: archivedSessions[sessionUUID],
                                colorScheme: colorScheme
                            )
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .swipeActions(edge: .trailing) {
                            Button {
                                restoreFromArchive(sessionUUID: sessionUUID)
                            } label: {
                                Label("Восстановить", systemImage: "arrow.uturn.backward")
                            }
                            .tint(.green)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .refreshable {
            await refreshChatList()
        }
    }
    
    private var connectionStatusOverlay: some View {
        Group {
            if !wsService.isConnected && !showLaunchScreen {
                HStack(spacing: 12) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 16))
                    
                    Text("Нет подключения")
                        .font(.system(size: 14, weight: .medium))
                    
                    Spacer()
                    
                    Button("Переподключиться") {
                        wsService.connect()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                    )
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: .red.opacity(0.3), radius: 15, y: 5)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }
    
    private func safeAreaTop() -> CGFloat {
        UIApplication.shared.windows.first?.safeAreaInsets.top ?? 44
    }
    
    private func initializeApp() {
        if !wsService.isConnected { wsService.connect() }
        setupSubscriptions()
        loadArchivedSessions()
        loadImportantChats()
        startStatusUpdates()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut) {
                showLaunchScreen = false
            }
        }
    }
    
    private func startStatusUpdates() {
        statusUpdateTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            for sessionUUID in activeSessions {
                wsService.requestClientStatus(for: sessionUUID)
            }
        }
    }
    
    private func loadData() {
        loadImportantChats()
        loadArchivedSessions()
        setupSubscriptions()
        startStatusUpdates()
    }
    
    private func cleanup() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        statusUpdateTimer?.invalidate()
        statusUpdateTimer = nil
    }
    
    private func loadImportantChats() {
        if let saved = UserDefaults.standard.array(forKey: "importantChats") as? [String] {
            importantChats = saved
        }
    }
    
    private func saveImportantChats() {
        UserDefaults.standard.set(importantChats, forKey: "importantChats")
    }
    
    private func loadArchivedSessions() {
        if let saved = UserDefaults.standard.dictionary(forKey: "archivedSessions") as? [String: Double] {
            archivedSessions = saved.mapValues { Date(timeIntervalSince1970: $0) }
        } else {
            archivedSessions = [:]
        }
        
        for sessionUUID in wsService.archivedSessions {
            if archivedSessions[sessionUUID] == nil {
                archivedSessions[sessionUUID] = Date()
            }
        }
        
        let serverArchivedSet = Set(wsService.archivedSessions)
        for sessionUUID in archivedSessions.keys {
            if !serverArchivedSet.contains(sessionUUID) {
                archivedSessions.removeValue(forKey: sessionUUID)
            }
        }
        
        print("📊 Загружено архивных сессий: \(archivedSessions.count)")
        saveArchivedSessions()
    }
    
    private func saveArchivedSessions() {
        let dict = archivedSessions.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(dict, forKey: "archivedSessions")
    }
    
    fileprivate func archiveSession(sessionUUID: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            archivedSessions[sessionUUID] = Date()
            saveArchivedSessions()
            wsService.send(dictionary: ["type": "archive_session", "session_uuid": sessionUUID])
        }
    }
    
    private func restoreFromArchive(sessionUUID: String) {
        withAnimation {
            archivedSessions.removeValue(forKey: sessionUUID)
            saveArchivedSessions()
            wsService.send(dictionary: ["type": "restore_session", "session_uuid": sessionUUID])
        }
    }
    
    private func setupSubscriptions() {
        wsService.sessionsDidUpdate
            .receive(on: DispatchQueue.main)
            .sink { [self] _ in
                self.loadArchivedSessions()
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: NSNotification.Name("ClientStatusChanged"))
            .receive(on: DispatchQueue.main)
            .sink { [self] _ in
                // Просто обновляем статусы
            }
            .store(in: &cancellables)
    }
    
    private func toggleImportantChat(sessionUUID: String) {
        if let index = importantChats.firstIndex(of: sessionUUID) {
            importantChats.remove(at: index)
        } else {
            importantChats.append(sessionUUID)
        }
        saveImportantChats()
    }
    
    private func refreshChatList() async {
        wsService.send(dictionary: ["type": "get_sessions"])
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
}

// MARK: - Chat Row View
struct ChatRowView: View {
    let sessionUUID: String
    let wsService: WebSocketService
    let isArchived: Bool
    let isImportant: Bool
    let archiveDate: Date?
    let colorScheme: ColorScheme
    
    private var clientStatus: WebClientStatus? {
        wsService.clientStatuses[sessionUUID]
    }
    
    private var lastMessage: Message? {
        wsService.sessions[sessionUUID]?.last
    }
    
    private var participant: String {
        let originalName = wsService.sessions[sessionUUID]?.first {
            $0.from != "iOSAdmin" && $0.from != "Поддержка"
        }?.from ?? "Клиент"
        
        let displayNames: [String: String] = [
            "Webvisitor_e4827": "Таня",
            "Webvisitor_a0598": "Майка",
        ]
        
        return displayNames[originalName] ?? originalName
    }
    
    private var preview: String {
        guard let msg = lastMessage else { return isArchived ? "Чат в архиве" : "Нет сообщений" }
        if msg.type == "file" {
            return "📎 \(msg.fileName ?? "Файл")"
        }
        return msg.message ?? ""
    }
    
    private var timeString: String {
        guard let ts = lastMessage?.timestamp else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    
    private var dateString: String {
        if isArchived, let archiveDate = archiveDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "dd.MM.yy"
            return "📦 \(formatter.string(from: archiveDate))"
        }
        
        guard let ts = lastMessage?.timestamp else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        let calendar = Calendar.current
        
        if calendar.isDateInToday(date) {
            return timeString
        } else if calendar.isDateInYesterday(date) {
            return "Вчера"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "dd.MM.yy"
            return formatter.string(from: date)
        }
    }
    
    private var statusIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(clientStatus?.isOnline == true ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            
            if let status = clientStatus {
                Text(status.statusText)
                    .font(.system(size: 11))
                    .foregroundColor(status.isOnline ? .green : .gray)
            } else {
                Text("")
                    .font(.system(size: 11))
            }
        }
        .opacity(clientStatus == nil ? 0 : 1)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(avatarColor)
                    .frame(width: 52, height: 52)
                
                if isArchived {
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.gray)
                } else if isImportant {
                    Image(systemName: "star.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.yellow)
                } else {
                    Text(String(participant.prefix(1).uppercased()))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(participant)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isArchived ? .secondary : .primary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text(dateString)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                
                Text(preview)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                
                if !isArchived {
                    statusIndicator
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        )
        .onAppear {
            if !isArchived {
                wsService.requestClientStatus(for: sessionUUID)
            }
        }
    }
    
    private var avatarColor: Color {
        if isArchived { return Color.gray.opacity(0.3) }
        if isImportant { return Color.yellow.opacity(0.3) }
        return Color.blue.opacity(0.2)
    }
}

// MARK: - Time Divider View
struct TimeDividerView: View {
    let timeString: String
    
    var body: some View {
        HStack {
            Spacer()
            Text(timeString)
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Modern Chat Detail View
struct ModernChatDetailView: View {
    let sessionUUID: String
    @ObservedObject var wsService = WebSocketService.shared
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var messageText = ""
    @State private var showDocumentPicker = false
    @State private var showActions = false
    @State private var showCloseAlert = false
    @State private var showSessionInfo = false
    @State private var showCallView = false
    @State private var cancellables = Set<AnyCancellable>()
    @State private var scrollProxy: ScrollViewProxy? = nil
    
    @State private var isNearBottom: Bool = true
    @State private var unreadCount: Int = 0
    @State private var lastReadMessageId: UUID? = nil
    @State private var hasUserScrolledUp: Bool = false
    
    private var clientStatus: WebClientStatus? {
        wsService.clientStatuses[sessionUUID]
    }
    
    private var messages: [Message] {
        wsService.sessions[sessionUUID] ?? []
    }
    
    private var participant: String {
        let originalName = messages.first {
            $0.from != "iOSAdmin" && $0.from != "Поддержка"
        }?.from ?? "Клиент"
        
        let displayNames: [String: String] = [
            "Webvisitor_e4827": "Таня",
            "Webvisitor_a0598": "Майка"
        ]
        
        return displayNames[originalName] ?? originalName
    }
    
    private var sortedMessages: [Message] {
        messages.filter { $0.type == "chat" || $0.type == "file" }
            .sorted { $0.timestamp < $1.timestamp }
    }
    
    private func groupMessagesByMinute(_ messages: [Message]) -> [[Message]] {
        var groups: [[Message]] = []
        var currentGroup: [Message] = []
        var lastTimestamp: Int64?
        
        for message in messages {
            let currentMinute = message.timestamp / 60000
            
            if let last = lastTimestamp {
                let lastMinute = last / 60000
                if currentMinute == lastMinute {
                    currentGroup.append(message)
                } else {
                    if !currentGroup.isEmpty {
                        groups.append(currentGroup)
                    }
                    currentGroup = [message]
                }
            } else {
                currentGroup = [message]
            }
            
            lastTimestamp = message.timestamp
        }
        
        if !currentGroup.isEmpty {
            groups.append(currentGroup)
        }
        
        return groups
    }
    
    private func formatTimeForDivider(timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    
    private var firstUnreadIndex: Int? {
        guard let lastReadId = lastReadMessageId else { return nil }
        return sortedMessages.firstIndex(where: { $0.id == lastReadId }).map { $0 + 1 }
    }
    
    var body: some View {
        ZStack {
            AppColors.backgroundGradient(for: colorScheme)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                chatHeaderView
                messagesListView
                inputAreaView
            }
            
            if !isNearBottom {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            scrollToBottom()
                        } label: {
                            HStack(spacing: 8) {
                                if unreadCount > 0 {
                                    Text("\(unreadCount)")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(6)
                                        .background(Circle().fill(Color.blue))
                                }
                                
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 16, weight: .bold))
                                
                                if unreadCount > 0 {
                                    Text("новых")
                                        .font(.system(size: 14))
                                }
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(Color.blue)
                                    .shadow(color: .blue.opacity(0.3), radius: 5, y: 2)
                            )
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, 10)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            
            if showCallView {
                CallOverlayView(
                    isPresented: $showCallView,
                    participantName: participant,
                    wsService: wsService,
                    sessionUUID: sessionUUID,
                    colorScheme: colorScheme
                )
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView { url in
                if let url = url {
                    wsService.currentMessageSessionUUID = sessionUUID
                    wsService.sendFile(fileURL: url)
                }
            }
        }
        .sheet(isPresented: $showSessionInfo) {
            SessionInfoView(sessionUUID: sessionUUID, messages: messages)
        }
        .actionSheet(isPresented: $showActions) {
            ActionSheet(
                title: Text("Действия"),
                buttons: [
                    .default(Text("Информация")) { showSessionInfo = true },
                    .default(Text("Экспорт")) { exportChat() },
                    .destructive(Text("Закрыть чат")) {
                        showCloseAlert = true
                    },
                    .cancel()
                ]
            )
        }
        .alert("Закрыть чат?", isPresented: $showCloseAlert) {
            Button("Отмена", role: .cancel) { }
            Button("Закрыть", role: .destructive) {
                wsService.closeSession(sessionUUID: sessionUUID)
                showAdminNotification(message: "✓ Чат закрыт для веб-клиента")
                presentationMode.wrappedValue.dismiss()
            }
        } message: {
            Text("Чат будет закрыт для веб-клиента и перемещен в архив")
        }
        .onAppear {
            wsService.currentMessageSessionUUID = sessionUUID
            setupSubscriptions()
            wsService.requestClientStatus(for: sessionUUID)
            loadLastReadMessage()
        }
        .onDisappear {
            cancellables.forEach { $0.cancel() }
        }
    }
    
    private func showAdminNotification(message: String) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              let rootView = window.rootViewController?.view else { return }
        
        let toastLabel = UILabel()
        toastLabel.text = message
        toastLabel.textColor = .white
        toastLabel.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.9)
        toastLabel.font = .systemFont(ofSize: 14, weight: .medium)
        toastLabel.textAlignment = .center
        toastLabel.layer.cornerRadius = 20
        toastLabel.clipsToBounds = true
        toastLabel.alpha = 0
        toastLabel.numberOfLines = 0
        
        let maxWidth: CGFloat = 250
        let textSize = (message as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: 1000),
            options: .usesLineFragmentOrigin,
            attributes: [.font: UIFont.systemFont(ofSize: 14)],
            context: nil
        ).size
        
        toastLabel.frame = CGRect(
            x: (rootView.bounds.width - textSize.width - 40) / 2,
            y: rootView.bounds.height - 120,
            width: textSize.width + 40,
            height: max(textSize.height + 20, 44)
        )
        
        rootView.addSubview(toastLabel)
        
        UIView.animate(withDuration: 0.3) {
            toastLabel.alpha = 1
        } completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 1.5, options: .curveEaseOut) {
                toastLabel.alpha = 0
            } completion: { _ in
                toastLabel.removeFromSuperview()
            }
        }
    }
    
    private var chatHeaderView: some View {
        HStack {
            Button {
                presentationMode.wrappedValue.dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.blue)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(participant)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.primary)
                        
                        if let status = clientStatus {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(status.isOnline ? Color.green : Color.gray)
                                    .frame(width: 6, height: 6)
                                
                                Text(status.statusText)
                                    .font(.caption)
                                    .foregroundColor(status.isOnline ? .green : .gray)
                            }
                        } else {
                            Text("")
                                .font(.caption)
                        }
                    }
                }
            }
            
            Spacer()
            
            HStack(spacing: 16) {
                Button {
                    CustomCallManager.shared.startCall(
                        sessionUUID: sessionUUID,
                        to: participant,
                        withVideo: false
                    )
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.blue)
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                        )
                }
                
                Button {
                    showActions = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18))
                        .foregroundColor(.blue)
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                        )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
    
    private var messagesListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if messages.count > 50 {
                        ProgressView()
                            .padding()
                            .onAppear {
                                loadMoreMessages()
                            }
                    }
                    
                    let groupedMessages = groupMessagesByMinute(sortedMessages)
                    
                    ForEach(Array(groupedMessages.enumerated()), id: \.offset) { groupIndex, group in
                        VStack(spacing: 8) {
                            if let firstMessage = group.first {
                                TimeDividerView(timeString: formatTimeForDivider(timestamp: firstMessage.timestamp))
                                    .id("time_\(firstMessage.timestamp)")
                            }
                            
                            ForEach(group) { message in
                                VStack(spacing: 2) {
                                    if let firstUnread = firstUnreadIndex,
                                       let messageIndex = sortedMessages.firstIndex(where: { $0.id == message.id }),
                                       messageIndex == firstUnread && unreadCount > 0 {
                                        HStack {
                                            Text("Новые сообщения")
                                                .font(.caption)
                                                .foregroundColor(.blue)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(
                                                    Capsule()
                                                        .fill(Color.blue.opacity(0.1))
                                                )
                                            
                                            Spacer()
                                        }
                                        .padding(.vertical, 8)
                                        .id("unread_separator")
                                    }
                                    
                                    MessageBubbleView(
                                        message: message,
                                        isOutgoing: message.from == "iOSAdmin",
                                        colorScheme: colorScheme
                                    )
                                    .id(message.id)
                                }
                            }
                        }
                    }
                    
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onAppear {
                self.scrollProxy = proxy
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let firstUnread = firstUnreadIndex,
                       firstUnread < sortedMessages.count,
                       firstUnread > 0 {
                        withAnimation {
                            proxy.scrollTo(sortedMessages[firstUnread].id, anchor: .top)
                        }
                        hasUserScrolledUp = true
                    } else {
                        withAnimation {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: sortedMessages.count) { newCount in
                updateUnreadCount()
                
                if !hasUserScrolledUp {
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .simultaneousGesture(
                DragGesture().onChanged { _ in
                    if !hasUserScrolledUp {
                        hasUserScrolledUp = true
                    }
                    checkIfNearBottom(proxy: proxy)
                }
            )
        }
    }
    
    private var inputAreaView: some View {
        HStack(spacing: 8) {
            Button {
                showDocumentPicker = true
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 18))
                    .foregroundColor(.blue)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                    )
            }
            
            HStack {
                TextField("Сообщение...", text: $messageText, axis: .vertical)
                    .font(.system(size: 16))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 22)
                            .fill(.ultraThinMaterial)
                    )
                
                if !messageText.isEmpty {
                    Button {
                        messageText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(messageText.isEmpty ? .gray : .blue)
            }
            .disabled(messageText.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
    
    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        wsService.sendChat(message: text)
        messageText = ""
        hasUserScrolledUp = false
        markAllAsRead()
    }
    
    private func scrollToBottom() {
        withAnimation {
            scrollProxy?.scrollTo("bottom", anchor: .bottom)
        }
        hasUserScrolledUp = false
        unreadCount = 0
        markAllAsRead()
    }
    
    private func checkIfNearBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // isNearBottom будет обновляться здесь
        }
    }
    
    private func updateUnreadCount() {
        guard let lastReadId = lastReadMessageId else {
            unreadCount = sortedMessages.filter { $0.from != "iOSAdmin" }.count
            return
        }
        
        if let lastReadIndex = sortedMessages.firstIndex(where: { $0.id == lastReadId }) {
            let newMessages = sortedMessages.suffix(from: lastReadIndex + 1)
                .filter { $0.from != "iOSAdmin" }
            unreadCount = newMessages.count
        }
    }
    
    private func markAllAsRead() {
        if let lastMessage = sortedMessages.last {
            lastReadMessageId = lastMessage.id
            UserDefaults.standard.set(lastMessage.id.uuidString, forKey: "last_read_\(sessionUUID)")
            unreadCount = 0
        }
    }
    
    private func loadLastReadMessage() {
        if let savedIdString = UserDefaults.standard.string(forKey: "last_read_\(sessionUUID)"),
           let savedId = UUID(uuidString: savedIdString) {
            lastReadMessageId = savedId
        }
        updateUnreadCount()
    }
    
    private func loadMoreMessages() {
        // Здесь будет загрузка более старых сообщений
    }
    
    private func exportChat() {
        var text = "=== Чат с \(participant) ===\n"
        text += "ID: \(sessionUUID)\n\n"
        
        for message in sortedMessages {
            let date = Date(timeIntervalSince1970: TimeInterval(message.timestamp) / 1000)
            let time = date.formatted(date: .omitted, time: .shortened)
            text += "[\(time)] \(message.from): "
            text += message.type == "file" ? "[ФАЙЛ] \(message.fileName ?? "")" : (message.message ?? "")
            text += "\n"
        }
        
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat_\(sessionUUID.prefix(6)).txt")
        
        try? text.write(to: url, atomically: true, encoding: .utf8)
        
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        UIApplication.shared.windows.first?.rootViewController?.present(av, animated: true)
    }
    
    private func setupSubscriptions() {
        NotificationCenter.default.publisher(for: NSNotification.Name("ClientStatusChanged"))
            .receive(on: DispatchQueue.main)
            .sink { [self] notification in
                if let notifSessionUUID = notification.userInfo?["sessionUUID"] as? String,
                   notifSessionUUID == sessionUUID {
                    // Просто обновляем статус
                }
            }
            .store(in: &cancellables)
    }
}

// MARK: - Message Bubble
struct MessageBubbleView: View {
    let message: Message
    let isOutgoing: Bool
    let colorScheme: ColorScheme
    @State private var showDownloadAlert = false
    
    private var isEmojiOnly: Bool {
        guard let text = message.message, !text.isEmpty else { return false }
        let emojis = text.filter { $0.isEmoji }
        return emojis.count == text.count && text.count <= 3
    }
    
    var body: some View {
        HStack {
            if isOutgoing { Spacer(minLength: 40) }
            
            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                if message.type == "file" {
                    fileMessageView
                } else {
                    textMessageView
                }
            }
            
            if !isOutgoing { Spacer(minLength: 40) }
        }
    }
    
    private var textMessageView: some View {
        Text(message.message ?? "")
            .font(.system(
                size: isEmojiOnly ? (message.message?.count == 1 ? 48 : 36) : 16
            ))
            .foregroundColor(isOutgoing ? .white : .primary)
            .padding(.horizontal, isEmojiOnly ? 8 : 16)
            .padding(.vertical, isEmojiOnly ? 4 : 12)
            .background(
                Group {
                    if !isEmojiOnly {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(isOutgoing ?
                                  AppColors.outgoingMessageColor(for: colorScheme) :
                                  AppColors.incomingMessageColor(for: colorScheme))
                    }
                }
            )
    }
    
    private var fileMessageView: some View {
        Button {
            showDownloadAlert = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: fileIcon)
                    .font(.system(size: 24))
                    .foregroundColor(.blue)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                    )
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.fileName ?? "Файл")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                
                Spacer(minLength: 0)
                
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 20))
                    .foregroundColor(.blue)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
            )
        }
        .alert("Скачать файл?", isPresented: $showDownloadAlert) {
            Button("Отмена", role: .cancel) { }
            Button("Скачать") {
                if let url = URL(string: message.fileUrl ?? "") {
                    UIApplication.shared.open(url)
                }
            }
        }
    }
    
    private var fileIcon: String {
        let name = message.fileName?.lowercased() ?? ""
        if name.hasSuffix(".pdf") { return "doc.fill" }
        if name.hasSuffix(".jpg") || name.hasSuffix(".png") { return "photo.fill" }
        if name.hasSuffix(".mp3") || name.hasSuffix(".m4a") { return "music.note" }
        if name.hasSuffix(".mp4") || name.hasSuffix(".mov") { return "film.fill" }
        if name.hasSuffix(".zip") || name.hasSuffix(".rar") { return "archivebox.fill" }
        return "doc.fill"
    }
}

// MARK: - Call Overlay
struct CallOverlayView: View {
    @Binding var isPresented: Bool
    let participantName: String
    let wsService: WebSocketService
    let sessionUUID: String
    let colorScheme: ColorScheme
    
    @State private var timer = "00:00"
    @State private var seconds = 0
    @State private var showExtra = false
    @State private var isMuted = false
    @State private var timerRef: Timer?
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.8)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 30) {
                Spacer()
                
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 100, height: 100)
                        .shadow(color: .blue.opacity(0.5), radius: 20)
                    
                    Text(String(participantName.prefix(1).uppercased()))
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(.white)
                }
                
                VStack(spacing: 8) {
                    Text(participantName)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                    
                    Text(timer)
                        .font(.system(size: 17, design: .monospaced))
                        .foregroundColor(.green)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.green.opacity(0.2))
                        )
                    
                    Text("Звонок")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.7))
                }
                
                Spacer()
                
                HStack(spacing: 30) {
                    callButton(
                        icon: isMuted ? "mic.slash.fill" : "mic.fill",
                        color: isMuted ? .red : .white
                    ) {
                        isMuted.toggle()
                    }
                    
                    ZStack {
                        ForEach(0..<5) { i in
                            Circle()
                                .fill(
                                    Color(
                                        hue: Double(i) * 0.2,
                                        saturation: 0.8,
                                        brightness: 0.9
                                    ).opacity(0.3)
                                )
                                .frame(width: 140, height: 140)
                                .scaleEffect(pulseScale)
                                .animation(
                                    Animation.easeInOut(duration: 2)
                                        .repeatForever(autoreverses: false)
                                        .delay(Double(i) * 0.3),
                                    value: pulseScale
                                )
                        }
                        
                        callButton(icon: "phone.down.fill", color: .red, size: 70) {
                            timerRef?.invalidate()
                            withAnimation { isPresented = false }
                        }
                    }
                    
                    callButton(icon: "speaker.wave.2.fill", color: .white) {
                        // toggle speaker
                    }
                }
                
                Button {
                    withAnimation { showExtra.toggle() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                        )
                        .rotationEffect(.degrees(showExtra ? 90 : 0))
                }
                .padding(.bottom, 20)
                
                if showExtra {
                    VStack(spacing: 12) {
                        extraOption(icon: "video", title: "Видеозвонок", color: .blue)
                        extraOption(icon: "person.crop.circle", title: "Пригласить", color: .purple)
                        extraOption(icon: "record.circle", title: "Запись", color: .orange)
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                
                Spacer()
            }
        }
        .onAppear(perform: startTimer)
        .onDisappear { timerRef?.invalidate() }
    }
    
    @State private var pulseScale: CGFloat = 0.8
    
    private func callButton(icon: String, color: Color, size: CGFloat = 60, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.4))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(color.opacity(0.3))
                        .background(.ultraThinMaterial)
                )
        }
    }
    
    private func extraOption(icon: String, title: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)
            
            Text(title)
                .font(.system(size: 15))
                .foregroundColor(.primary)
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private func startTimer() {
        withAnimation(Animation.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
            pulseScale = 1.3
        }
        
        timerRef = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            seconds += 1
            let mins = seconds / 60
            let secs = seconds % 60
            timer = String(format: "%02d:%02d", mins, secs)
        }
    }
}

// MARK: - Session Info View
struct SessionInfoView: View {
    let sessionUUID: String
    let messages: [Message]
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        NavigationView {
            List {
                Section("Информация") {
                    infoRow("ID", sessionUUID)
                    infoRow("Участник", messages.first { $0.from != "iOSAdmin" && $0.from != "Поддержка" }?.from ?? "Клиент")
                    if let first = messages.first {
                        infoRow("Создан", Date(timeIntervalSince1970: TimeInterval(first.timestamp) / 1000).formatted())
                    }
                }
                
                Section("Статистика") {
                    infoRow("Сообщений", "\(messages.count)")
                    infoRow("Файлов", "\(messages.filter { $0.type == "file" }.count)")
                }
                
                Section {
                    Button("Копировать ID") {
                        UIPasteboard.general.string = sessionUUID
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.backgroundGradient(for: colorScheme))
            .navigationTitle("Информация")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
    
    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundColor(.secondary)
            Spacer()
            Text(value).foregroundColor(.primary)
        }
    }
}

// MARK: - Document Picker
struct DocumentPickerView: UIViewControllerRepresentable {
    var onPick: (URL?) -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPickerView
        
        init(_ parent: DocumentPickerView) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                parent.onPick(nil)
                return
            }
            
            let tempDir = FileManager.default.temporaryDirectory
            let tempURL = tempDir.appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
            
            try? FileManager.default.copyItem(at: url, to: tempURL)
            parent.onPick(tempURL)
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onPick(nil)
        }
    }
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item, .data, .pdf, .image, .audio, .video], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}

// MARK: - Helper Extensions
extension Character {
    var isEmoji: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar.properties.isEmoji
    }
}

// MARK: - Preview
struct ChatListView_Previews: PreviewProvider {
    static var previews: some View {
        ChatListView()
    }
}
