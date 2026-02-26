import SwiftUI

@main
struct WhisperCallApp: App {
    @StateObject private var wsService = WebSocketService.shared
    @StateObject private var rtcManager = WebRTCManager.shared
    @StateObject private var callManager = CustomCallManager.shared
    @State private var showCallView = false
    @State private var hasServerConfig = false
    @State private var isCheckingServer = true
    
    init() {
        // Проверяем, есть ли сохраненный сервер при запуске
        let savedServer = UserDefaults.standard.string(forKey: "serverURL")
        _hasServerConfig = State(initialValue: savedServer != nil && !savedServer!.isEmpty)
    }

    var body: some Scene {
        WindowGroup {
            NavigationView {
                ZStack {
                    if isCheckingServer {
                        // Используем LaunchScreenView из основного файла (он уже есть в проекте)
                        // Не объявляем новый, а используем существующий
                        LaunchScreenView()
                            .onAppear {
                                checkServerConfiguration()
                            }
                    } else if !hasServerConfig {
                        // Если нет сервера - показываем настройку
                        ServerSetupView(
                            wsService: wsService,
                            onComplete: {
                                withAnimation {
                                    hasServerConfig = true
                                }
                            }
                        )
                        .environmentObject(wsService)
                        .transition(.opacity)
                    } else {
                        // Если сервер есть - показываем чаты
                        ChatListView()
                            .environmentObject(wsService)
                            .environmentObject(rtcManager)
                            .environmentObject(callManager)
                            .transition(.opacity)
                            .onAppear {
                                if !wsService.isConnected {
                                    wsService.connect()
                                }
                            }
                    }
                    
                    // Показываем кастомный интерфейс звонка
                    if callManager.callState != .idle {
                        CustomCallView()
                            .transition(.opacity)
                            .zIndex(1)
                    }
                }
                .navigationBarHidden(true)
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowIncomingCallUI"))) { _ in
                    withAnimation {
                        showCallView = true
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ServerConfigChanged"))) { notification in
                    if let hasConfig = notification.userInfo?["hasConfig"] as? Bool {
                        withAnimation {
                            hasServerConfig = hasConfig
                        }
                    }
                }
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
    }
    
    private func checkServerConfiguration() {
        // Имитация проверки (можно убрать задержку)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation {
                isCheckingServer = false
            }
        }
    }
}

// MARK: - ServerSetupView (только этот оставляем, так как он уникален для этого файла)
struct ServerSetupView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var wsService: WebSocketService
    var onComplete: (() -> Void)?
    
    @State private var serverInput: String = ""
    @State private var isValidURL: Bool = true
    @State private var isConnecting: Bool = false
    @State private var connectionError: String?
    
    // Примеры серверов
    let examples = [
        "wss://your-server.com/ws",
        "ws://localhost:8080/ws"
    ]
    
    var body: some View {
        ZStack {
            // Используем AppColors из CommonTypes
            AppColors.backgroundGradient(for: colorScheme)
                .edgesIgnoringSafeArea(.all)
            
            ScrollView {
                VStack(spacing: 32) {
                    // Логотип и информация о приложении
                    VStack(spacing: 24) {
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
                    .padding(.top, 40)
                    
                    // Разделитель
                    VStack(spacing: 16) {
                        Rectangle()
                            .frame(height: 1)
                            .foregroundColor(.secondary.opacity(0.3))
                        
                        Text("Настройка подключения к серверу")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 40)
                    
                    // Поле ввода сервера
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Адрес WebSocket сервера:")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        HStack {
                            Image(systemName: "network")
                                .foregroundColor(.blue)
                                .frame(width: 24)
                            
                            TextField("wss://ваш-сервер.com/ws", text: $serverInput)
                                .font(.system(size: 16))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .keyboardType(.URL)
                                .textContentType(.URL)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.ultraThinMaterial)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(!isValidURL ? Color.red : Color.clear, lineWidth: 1)
                        )
                        
                        if !isValidURL {
                            Text("Введите корректный URL (начинается с ws:// или wss://)")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        
                        // Примеры URL
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Примеры:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            ForEach(examples, id: \.self) { example in
                                HStack {
                                    Image(systemName: "doc.on.clipboard")
                                        .font(.system(size: 10))
                                        .foregroundColor(.blue)
                                    
                                    Text(example)
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(8)
                                .onTapGesture {
                                    serverInput = example
                                    isValidURL = true
                                }
                            }
                        }
                        .padding(.top, 4)
                        
                        // Информация о файлах
                        VStack(alignment: .leading, spacing: 8) {
                            Label(
                                title: { Text("Файлы будут загружаться на этот же сервер") },
                                icon: { Image(systemName: "folder.fill") }
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)
                            
                            Label(
                                title: { Text("Путь для загрузки: /upload.php") },
                                icon: { Image(systemName: "arrow.up.doc.fill") }
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)
                            
                            Label(
                                title: { Text("Файлы доступны по адресу: /uploads/имя_файла") },
                                icon: { Image(systemName: "arrow.down.doc.fill") }
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                        .padding(.top, 8)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 12)
                        .background(Color.blue.opacity(0.05))
                        .cornerRadius(12)
                    }
                    .padding(.horizontal, 24)
                    
                    // Кнопка подключения
                    Button(action: connectToServer) {
                        HStack {
                            if isConnecting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .padding(.trailing, 8)
                            }
                            
                            Image(systemName: "link")
                                .font(.system(size: 16))
                            
                            Text(isConnecting ? "Подключение..." : "Подключиться к серверу")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(16)
                        .padding(.horizontal, 24)
                    }
                    .disabled(isConnecting || !isValidURLFormat(serverInput))
                    
                    // Статус подключения
                    if let error = connectionError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(12)
                        .padding(.horizontal, 24)
                    }
                    
                    // Кнопка связи с разработчиком
                    Button(action: showContactInfo) {
                        Text("Демо сервер. Связаться с разработчиком")
                            .font(.caption)
                            .foregroundColor(.blue)
                            .underline()
                    }
                    .padding(.top, 8)
                    
                    Spacer()
                }
                .padding(.bottom, 20)
            }
        }
        .onAppear {
            // Если уже есть сохраненный сервер, показываем его
            if let saved = UserDefaults.standard.string(forKey: "serverURL") {
                serverInput = saved
            }
        }
        .alert("Связаться с разработчиком", isPresented: $showContactAlert) {
            Button("Копировать email") {
                UIPasteboard.general.string = "jbabov@me.com"
                showCopyConfirmation = true
            }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Получить демо доступ:\njbabov@me.com")
        }
        .overlay(
            // Всплывающее уведомление о копировании
            Group {
                if showCopyConfirmation {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Email скопирован")
                                .foregroundColor(.white)
                        }
                        .padding()
                        .background(Color.green.opacity(0.8))
                        .cornerRadius(12)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation {
                                    showCopyConfirmation = false
                                }
                            }
                        }
                    }
                }
            }
        )
    }
    
    // Новые состояния
    @State private var showContactAlert = false
    @State private var showCopyConfirmation = false
    
    private func isValidURLFormat(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.hasPrefix("ws://") || trimmed.hasPrefix("wss://")) && trimmed.count > 6
    }
    
    private func showContactInfo() {
        showContactAlert = true
    }
    
    private func connectToServer() {
        let trimmedURL = serverInput.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard isValidURLFormat(trimmedURL) else {
            isValidURL = false
            return
        }
        
        isValidURL = true
        isConnecting = true
        connectionError = nil
        
        // Сохраняем URL в UserDefaults
        UserDefaults.standard.set(trimmedURL, forKey: "serverURL")
        
        // Обновляем URL в WebSocketService и подключаемся
        wsService.updateServerURL(trimmedURL)
        
        // Даем время на подключение
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [self] in
            isConnecting = false
            
            if wsService.isConnected {
                // Успешно подключились
                print("✅ Connected to server: \(trimmedURL)")
                
                // Отправляем уведомление об изменении конфигурации
                NotificationCenter.default.post(
                    name: NSNotification.Name("ServerConfigChanged"),
                    object: nil,
                    userInfo: ["hasConfig": true]
                )
                
                // Вызываем completion
                onComplete?()
            } else {
                // Ошибка подключения
                connectionError = "Не удалось подключиться к серверу. Проверьте адрес и попробуйте снова."
                print("❌ Failed to connect to server: \(trimmedURL)")
            }
        }
    }
}
