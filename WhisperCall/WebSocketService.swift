//
//  WebSocketService.swift
//  Whisper Call
//
//  Created by Jordan Babov on 19.02.2026.
//

import Foundation
import Combine
import WebRTC
import MobileCoreServices
import UniformTypeIdentifiers
import UIKit
import UserNotifications

// Импортируем общие типы
// WebClientStatus теперь импортируется из CommonTypes

class WebSocketService: ObservableObject {
    static let shared = WebSocketService()
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var heartbeatTimer: Timer?
    
    // Для отслеживания обновлений сессий
    private var sessionUpdatePublisher = PassthroughSubject<String, Never>()
    
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var reconnectionAttempts = 0
    private let maxReconnectionAttempts = 10
    private var receivedMessageHashes = Set<String>()
    private let maxHashes = 1000
    
    private var isReconnecting = false
    private var reconnectTimer: Timer?
    private var lastReconnectTime: Date?
    private var shouldReconnect = true
    
    @Published var isConnected: Bool = false
    @Published var currentMessageSessionUUID: String?
    @Published var currentCallSessionUUID: String?
    @Published var sessions: [String: [Message]] = [:]
    @Published var archivedSessions: [String] = []
    
    // Ключ для сохранения архива в UserDefaults
    private let archivedSessionsKey = "archivedSessionsKey"
    
    // Статусы веб-клиентов (ключ - sessionUUID)
    @Published var clientStatuses: [String: WebClientStatus] = [:]
    
    // Защита от частых запросов статусов
    private var lastClientStatusRequest: [String: Date] = [:]
    
    // Для отслеживания обновлений сессий
    private var sessionsUpdatePublisher = PassthroughSubject<(), Never>()
    var sessionsDidUpdate: AnyPublisher<(), Never> {
        sessionsUpdatePublisher.eraseToAnyPublisher()
    }
    
    // ИЗМЕНЕНО: Динамические URL из UserDefaults
    private var serverURL: URL? {
        guard let urlString = UserDefaults.standard.string(forKey: "serverURL"), !urlString.isEmpty else {
            print("⚠️ No server URL configured")
            return nil
        }
        return URL(string: urlString)
    }
    
    private var baseURL: String {
        guard let urlString = UserDefaults.standard.string(forKey: "serverURL"), !urlString.isEmpty else {
            return "https://otvet-dz.online" // fallback, но лучше не использовать
        }
        
        // Конвертируем wss:// в https:// и убираем /ws
        var base = urlString
            .replacingOccurrences(of: "/ws", with: "")
            .replacingOccurrences(of: "/wss", with: "")
        
        if base.hasPrefix("wss://") {
            base = base.replacingOccurrences(of: "wss://", with: "https://")
        } else if base.hasPrefix("ws://") {
            base = base.replacingOccurrences(of: "ws://", with: "http://")
        }
        
        if base.hasSuffix("/") {
            base = String(base.dropLast())
        }
        
        return base
    }
    
    private var uploadURL: URL {
        return URL(string: "\(baseURL)/upload.php") ?? URL(string: "https://otvet-dz.online/upload.php")!
    }
    
    private var clientId: String = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    private var isAdmin: Bool = true
    
    // Для временных сообщений
    private var tempMessages: [String: UUID] = [:] // Ключ: "sessionUUID_timestamp_messageHash"
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 10
        config.allowsCellularAccess = true
        urlSession = URLSession(configuration: config, delegate: nil, delegateQueue: OperationQueue())
        setupNotifications()
        setupBackgroundNotifications()
        
        // Загружаем архивные сессии при старте
        loadArchivedSessions()
    }
    
    private func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
    
    private func setupBackgroundNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    private func nowMs() -> Int64 {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        print("🕐 Generated timestamp for sending: \(ms)")
        return ms
    }
    
    // НОВЫЙ МЕТОД: Обновление URL сервера
    func updateServerURL(_ newURL: String) {
        print("🔧 Updating server URL to: \(newURL)")
        
        // Отключаемся от текущего сервера
        disconnect()
        
        // Очищаем все данные
        DispatchQueue.main.async {
            self.sessions.removeAll()
            self.archivedSessions.removeAll()
            self.clientStatuses.removeAll()
            self.tempMessages.removeAll()
            self.receivedMessageHashes.removeAll()
        }
        
        // Сохраняем новый URL
        UserDefaults.standard.set(newURL, forKey: "serverURL")
        
        // Подключаемся к новому серверу
        connect()
    }
    
    // ИЗМЕНЕНО: Используем динамический URL
    func connect() {
        guard let serverURL = serverURL else {
            print("⚠️ No server configured, waiting for user input")
            DispatchQueue.main.async {
                self.isConnected = false
            }
            return
        }
        
        print("🔗 connect() called with server: \(serverURL.absoluteString)")
        
        guard !isReconnecting else {
            print("⚠️ Already reconnecting, skipping duplicate connect")
            return
        }
        
        cancelReconnect()
        
        if webSocketTask != nil {
            disconnect()
        }
        
        isReconnecting = false
        shouldReconnect = true
        
        webSocketTask = urlSession.webSocketTask(with: serverURL)
        webSocketTask?.resume()
        
        DispatchQueue.main.async {
            self.isConnected = true
            self.reconnectionAttempts = 0
        }
        
        startHeartbeat()
        listen()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.registerClient()
        }
        
        print("✅ WebSocket connection initiated to: \(serverURL.absoluteString)")
    }
    
    func disconnect() {
        print("🔌 disconnect() called")
        
        cancelReconnect()
        endBackgroundTask()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        
        DispatchQueue.main.async {
            self.isConnected = false
            self.tempMessages.removeAll()
        }
        
        print("✅ WebSocket disconnected")
    }
    
    private func reconnect() {
        print("🔄 reconnect() called, attempts: \(reconnectionAttempts)")
        
        guard shouldReconnect else {
            print("⚠️ Reconnect disabled, skipping")
            return
        }
        
        guard !isReconnecting else {
            print("⚠️ Already reconnecting, skipping")
            return
        }
        
        guard reconnectionAttempts < maxReconnectionAttempts else {
            print("❌ Max reconnection attempts reached (\(maxReconnectionAttempts))")
            isReconnecting = false
            shouldReconnect = false
            return
        }
        
        if let lastReconnect = lastReconnectTime {
            let timeSinceLast = Date().timeIntervalSince(lastReconnect)
            if timeSinceLast < 1.0 {
                print("⚠️ Too soon since last reconnect (\(String(format: "%.1f", timeSinceLast))s), delaying...")
                DispatchQueue.main.asyncAfter(deadline: .now() + (1.0 - timeSinceLast)) { [weak self] in
                    self?.reconnect()
                }
                return
            }
        }
        
        isReconnecting = true
        reconnectionAttempts += 1
        lastReconnectTime = Date()
        
        let baseDelay = 2.0
        let maxDelay = 30.0
        let delay = min(baseDelay * pow(1.5, Double(reconnectionAttempts - 1)), maxDelay)
        
        print("🔄 Reconnection attempt \(reconnectionAttempts) in \(String(format: "%.1f", delay))s...")
        
        reconnectTimer?.invalidate()
        
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            
            print("🔄 Executing reconnection attempt \(self.reconnectionAttempts)")
            self.isReconnecting = false
            
            if !self.isConnected {
                self.connect()
            } else {
                print("✅ Already connected, skipping reconnect")
            }
        }
    }
    
    private func cancelReconnect() {
        print("⏹️ cancelReconnect() called")
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        isReconnecting = false
        reconnectionAttempts = 0
    }
    
    func closeSession(sessionUUID: String) {
        let message: [String: Any] = [
            "type": "close_session",
            "session_uuid": sessionUUID
        ]
        send(dictionary: message)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let _ = self.sessions.removeValue(forKey: sessionUUID) {
                // Добавляем в архив, если ещё не там
                if !self.archivedSessions.contains(sessionUUID) {
                    self.archivedSessions.append(sessionUUID)
                }
                // СОХРАНЯЕМ В USERDEFAULTS
                self.saveArchivedSessions()
                print("✅ Сессия закрыта и перемещена в архив: \(sessionUUID)")
                self.sessionsUpdatePublisher.send()
            }
            if self.currentMessageSessionUUID == sessionUUID {
                self.currentMessageSessionUUID = nil
            }
            if self.currentCallSessionUUID == sessionUUID {
                self.currentCallSessionUUID = nil
            }
            // Удаляем статус клиента при закрытии сессии
            self.clientStatuses.removeValue(forKey: sessionUUID)
        }
    }
    
    func archiveSession(sessionUUID: String) {
        let message: [String: Any] = [
            "type": "archive_session",
            "session_uuid": sessionUUID
        ]
        send(dictionary: message)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let _ = self.sessions.removeValue(forKey: sessionUUID) {
                self.archivedSessions.append(sessionUUID)
                print("✅ Сессия архивирована: \(sessionUUID)")
                self.sessionsUpdatePublisher.send()
            }
            if self.currentMessageSessionUUID == sessionUUID {
                self.currentMessageSessionUUID = nil
            }
            if self.currentCallSessionUUID == sessionUUID {
                self.currentCallSessionUUID = nil
            }
        }
    }
    
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }
    
    private func startBackgroundHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: 30,
            repeats: true
        ) { [weak self] _ in
            self?.sendPing()
        }
    }
    
    private func sendPing() {
        guard isConnected else { return }
        webSocketTask?.sendPing { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                print("❌ Ping error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isConnected = false
                    if self.shouldReconnect {
                        self.reconnect()
                    }
                }
            } else {
                print("💓 Ping sent successfully")
            }
        }
    }
    
    @objc private func appDidEnterBackground() {
        print("📱 App entered background")
        
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            print("⚠️ Background task expired")
            self?.endBackgroundTask()
        }
        
        startBackgroundHeartbeat()
    }
    
    @objc private func appWillEnterForeground() {
        print("📱 App entered foreground")
        
        endBackgroundTask()
        heartbeatTimer?.invalidate()
        startHeartbeat()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if !self.isConnected {
                print("🔄 Reconnecting after foreground...")
                self.reconnect()
            } else {
                print("✅ Already connected, sending ping...")
                self.sendPing()
            }
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    
    private func registerClient() {
        guard !clientId.isEmpty else { return }
        
        let register: [String: Any] = [
            "type": "register",
            "clientId": clientId,
            "isAdmin": isAdmin,
            "name": "iOSAdmin"
        ]
        send(dictionary: register, skipDuplicateCheck: true)
    }
    
    private func listen() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .failure(let error):
                let nsError = error as NSError
                print("❌ WebSocket receive error: \(error.localizedDescription), code: \(nsError.code)")
                
                DispatchQueue.main.async {
                    self.isConnected = false
                    
                    switch nsError.code {
                    case 57:
                        print("🔌 Socket not connected, will reconnect")
                        if self.shouldReconnect {
                            self.reconnect()
                        }
                    case 89:
                        print("⏹️ Operation cancelled")
                    default:
                        print("⚠️ Other error, will reconnect")
                        if self.shouldReconnect {
                            self.reconnect()
                        }
                    }
                }
                
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default: break
                }
                
                if self.isConnected {
                    self.listen()
                }
            }
        }
    }
    
    // ИСПРАВЛЕННАЯ ФУНКЦИЯ: handleMessage с добавлением client_status
    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        
        print("📥 Received message type: \(type)")
        
        if type == "registered" {
            print("✅ Successfully registered with server")
            reconnectionAttempts = 0
            isReconnecting = false
            
            if let session_uuid = json["session_uuid"] as? String {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.currentMessageSessionUUID = session_uuid
                    self.currentCallSessionUUID = session_uuid
                    if self.sessions[session_uuid] == nil {
                        self.sessions[session_uuid] = []
                    }
                    self.sessionsUpdatePublisher.send()
                }
            }
            return
        }
        
        let timestamp = json["timestamp"] as? Int64 ?? 0
        let from = json["from"] as? String ?? ""
        let message = json["message"] as? String ?? ""
        let fileUrl = json["fileUrl"] as? String ?? ""
        
        let messageHash = "\(timestamp)_\(from)_\(message)_\(fileUrl)_\(type)"
        
        if ["chat", "file"].contains(type) && receivedMessageHashes.contains(messageHash) {
            print("⚠️ Ignoring duplicate \(type) message from \(from)")
            return
        }
        
        if ["chat", "file"].contains(type) {
            receivedMessageHashes.insert(messageHash)
            
            if receivedMessageHashes.count > maxHashes {
                let excess = receivedMessageHashes.count - maxHashes / 2
                let oldHashes = Array(receivedMessageHashes.prefix(excess))
                oldHashes.forEach { receivedMessageHashes.remove($0) }
            }
        }
        
        switch type {
        case "sessions":
            if let sessionsArray = json["sessions"] as? [[String: Any]] {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    for s in sessionsArray {
                        if let session_uuid = s["session_uuid"] as? String,
                           self.sessions[session_uuid] == nil {
                            self.sessions[session_uuid] = []
                        }
                    }
                    self.sessionsUpdatePublisher.send()
                }
            }
            
        case "history":
            if let session_uuid = json["session_uuid"] as? String,
               let messagesArray = json["messages"] as? [[String: Any]] {
                let messages = messagesArray.compactMap { Message.from(dict: $0) }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.sessions[session_uuid] = messages
                    self.sessionsUpdatePublisher.send()
                }
            }
            
        case "chat":
            if let session_uuid = json["session_uuid"] as? String,
               let msg = Message.from(dict: json) {
                
                // ЛОГИРОВАНИЕ ДЛЯ ОТЛАДКИ TIMESTAMP
                print("📱 RAW timestamp from server: \(timestamp)")
                print("📱 Parsed timestamp: \(msg.timestamp)")
                print("📱 Message: \(msg.message ?? "") from \(msg.from)")
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // ВАЖНОЕ ИСПРАВЛЕНИЕ: Убедимся, что массив существует
                    if self.sessions[session_uuid] == nil {
                        self.sessions[session_uuid] = []
                    }
                    
                    let isFromMe = msg.from == "iOSAdmin"
                    
                    if isFromMe {
                        // ИСПРАВЛЕНО: Находим и заменяем временное сообщение
                        let messageKey = "\(session_uuid)_\(msg.timestamp)_\((msg.message ?? "").hashValue)"
                        
                        if let tempMessageId = self.tempMessages[messageKey],
                           let index = self.sessions[session_uuid]?.firstIndex(where: { $0.id == tempMessageId }) {
                            // Заменяем временное сообщение на серверное
                            print("🔄 Replacing temp message with server echo: \(msg.message ?? "")")
                            self.sessions[session_uuid]?[index] = msg
                            self.tempMessages.removeValue(forKey: messageKey)
                        } else {
                            // Если не нашли временное, проверяем на дубликат и добавляем
                            let exists = self.sessions[session_uuid]?.contains(where: {
                                $0.timestamp == msg.timestamp &&
                                $0.from == msg.from &&
                                $0.message == msg.message
                            }) ?? false
                            
                            if !exists {
                                print("✅ Adding chat message echo from server: \(msg.message ?? "")")
                                self.sessions[session_uuid]?.append(msg)
                            }
                        }
                    } else {
                        // Сообщение от другого пользователя
                        let exists = self.sessions[session_uuid]?.contains(where: {
                            $0.timestamp == msg.timestamp &&
                            $0.from == msg.from &&
                            $0.message == msg.message
                        }) ?? false
                        
                        if !exists {
                            print("✅ Chat message added from \(msg.from), session updated")
                            self.sessions[session_uuid]?.append(msg)
                        }
                    }
                    
                    self.sessionsUpdatePublisher.send()
                }
            }
            
        case "file":
            if let session_uuid = json["session_uuid"] as? String,
               let msg = Message.from(dict: json) {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if self.sessions[session_uuid] == nil {
                        self.sessions[session_uuid] = []
                    }
                    
                    let isFromMe = msg.from == "iOSAdmin"
                    
                    if isFromMe {
                        // Для файлов используем timestamp и fileName для поиска временного сообщения
                        let messageKey = "\(session_uuid)_\(msg.timestamp)_\(msg.fileName ?? "file")"
                        
                        if let tempMessageId = self.tempMessages[messageKey],
                           let index = self.sessions[session_uuid]?.firstIndex(where: { $0.id == tempMessageId }) {
                            // Заменяем временное сообщение на серверное
                            print("🔄 Replacing temp file message with server echo: \(msg.fileName ?? "unknown")")
                            self.sessions[session_uuid]?[index] = msg
                            self.tempMessages.removeValue(forKey: messageKey)
                        } else {
                            // Проверяем на дубликат
                            let exists = self.sessions[session_uuid]?.contains(where: {
                                $0.timestamp == msg.timestamp &&
                                $0.fileName == msg.fileName &&
                                $0.fileUrl == msg.fileUrl
                            }) ?? false
                            
                            if !exists {
                                print("✅ File message echo from server: \(msg.fileName ?? "unknown")")
                                self.sessions[session_uuid]?.append(msg)
                            }
                        }
                    } else {
                        // Файл от другого пользователя
                        let exists = self.sessions[session_uuid]?.contains(where: {
                            $0.timestamp == msg.timestamp &&
                            $0.fileName == msg.fileName &&
                            $0.fileUrl == msg.fileUrl
                        }) ?? false
                        
                        if !exists {
                            print("✅ File message added from \(msg.from): \(msg.fileName ?? "unknown"), session updated")
                            self.sessions[session_uuid]?.append(msg)
                            self.showFileNotification(for: msg)
                        }
                    }
                    
                    self.sessionsUpdatePublisher.send()
                }
            }
            
        // НОВОЕ: Обработка call_log
        case "call_log":
            if let session_uuid = json["session_uuid"] as? String,
               let msg = Message.from(dict: json) {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if self.sessions[session_uuid] == nil {
                        self.sessions[session_uuid] = []
                    }
                    
                    self.sessions[session_uuid]?.append(msg)
                    self.sessionsUpdatePublisher.send()
                    print("📞 Call log received: \(msg.callLogText)")
                }
            }
            
        // НОВОЕ: Обработка статуса веб-клиента - ИСПРАВЛЕНО с принудительным обновлением
        case "client_status":
            if let sessionUUID = json["session_uuid"] as? String,
               let clientName = json["client_name"] as? String,
               let status = json["status"] as? String {
                
                let lastSeen = json["last_seen"] as? Int64
                print("📊 Client status for session \(sessionUUID): \(status), client: \(clientName)")
                
                let clientStatus = WebClientStatus(
                    sessionUUID: sessionUUID,
                    clientName: clientName,
                    isOnline: status == "online",
                    lastSeen: lastSeen.flatMap { Date(timeIntervalSince1970: TimeInterval($0)) }
                )
                
                DispatchQueue.main.async {
                    // Обновляем статус
                    self.clientStatuses[sessionUUID] = clientStatus
                    // ПРИНУДИТЕЛЬНО обновляем UI
                    self.objectWillChange.send()
                    self.sessionsUpdatePublisher.send()
                    
                    // Отправляем уведомление для обновления UI
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ClientStatusChanged"),
                        object: nil,
                        userInfo: [
                            "sessionUUID": sessionUUID,
                            "status": status,
                            "clientName": clientName,
                            "lastSeen": lastSeen ?? 0
                        ]
                    )
                }
            }
            
        case "session_closed":
            if let session_uuid = json["session_uuid"] as? String {
                print("📥 Received session_closed for: \(session_uuid)")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let _ = self.sessions.removeValue(forKey: session_uuid) {
                        // Добавляем в архив, если ещё не там
                        if !self.archivedSessions.contains(session_uuid) {
                            self.archivedSessions.append(session_uuid)
                        }
                        // СОХРАНЯЕМ В USERDEFAULTS
                        self.saveArchivedSessions()
                        print("✅ Сессия удалена из активных: \(session_uuid)")
                        self.sessionsUpdatePublisher.send()
                    }
                    // Удаляем статус клиента при закрытии сессии
                    self.clientStatuses.removeValue(forKey: session_uuid)
                    
                    if self.currentMessageSessionUUID == session_uuid {
                        self.currentMessageSessionUUID = nil
                    }
                    if self.currentCallSessionUUID == session_uuid {
                        self.currentCallSessionUUID = nil
                    }
                }
            }
            
        case "session_archived":
            if let session_uuid = json["session_uuid"] as? String {
                print("📥 Received session_archived for: \(session_uuid)")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let _ = self.sessions.removeValue(forKey: session_uuid) {
                        // Добавляем в архив, если ещё не там
                        if !self.archivedSessions.contains(session_uuid) {
                            self.archivedSessions.append(session_uuid)
                        }
                        // СОХРАНЯЕМ В USERDEFAULTS
                        self.saveArchivedSessions()
                        print("✅ Сессия архивирована сервером: \(session_uuid)")
                        self.sessionsUpdatePublisher.send()
                    }
                    if self.currentMessageSessionUUID == session_uuid {
                        self.currentMessageSessionUUID = nil
                    }
                    if self.currentCallSessionUUID == session_uuid {
                        self.currentCallSessionUUID = nil
                    }
                }
            }
            
        case "call_offer":
            guard let sdp = json["sdp"] as? String,
                  let callId = json["callId"] as? String else { return }
            
            let sessionUUID = (json["session_uuid"] as? String) ?? currentCallSessionUUID
            guard let finalSessionUUID = sessionUUID else { return }
            
            // ВАЖНО: Получаем информацию о видео
            let hasVideo = json["hasVideo"] as? Bool ?? false
            print("📥 Received call_offer with hasVideo: \(hasVideo)")
            
            DispatchQueue.main.async {
                self.currentCallSessionUUID = finalSessionUUID
            }
            
            WebRTCManager.shared.receiveCall(
                sessionUUID: finalSessionUUID,
                callId: callId,
                sdp: sdp,
                hasVideo: hasVideo // Передаем параметр
            )
            break
            
        case "call_answer":
            if let sdp = json["sdp"] as? String {
                Task { await WebRTCManager.shared.setRemoteAnswer(sdp: sdp) }
            }
            
        case "ice_candidate":
            if let cand = json["candidate"] as? [String: Any],
               let sdp = cand["candidate"] as? String,
               let sdpMLineIndex = cand["sdpMLineIndex"] as? Int32,
               let sdpMid = cand["sdpMid"] as? String {
                let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
                WebRTCManager.shared.addRemoteIceCandidate(candidate)
            }
            
        case "call_end":
            WebRTCManager.shared.endCall()
            
        default:
            print("⚠️ Unknown message type: \(type)")
        }
    }
    
    private func showFileNotification(for message: Message) {
        guard let fileName = message.fileName, message.from != "iOSAdmin" else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Новый файл"
        content.body = "\(message.from) отправил(а): \(fileName)"
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    // ИСПРАВЛЕННАЯ ФУНКЦИЯ: sendChat
    func sendChat(message: String) {
        guard let session_uuid = currentMessageSessionUUID else { return }
        let timestamp = nowMs()
        
        // Создаем временный ID для сообщения
        let tempMessageId = UUID()
        let tempMessage = Message(
            id: tempMessageId,
            from: "iOSAdmin",
            to: "",
            type: "chat",
            message: message,
            fileName: nil,
            fileUrl: nil,
            timestamp: timestamp,
            callDuration: nil
        )
        
        // Сохраняем временный ID для последующего обновления
        let messageKey = "\(session_uuid)_\(timestamp)_\(message.hashValue)"
        tempMessages[messageKey] = tempMessageId
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.sessions[session_uuid] == nil {
                self.sessions[session_uuid] = []
            }
            // Добавляем временное сообщение
            self.sessions[session_uuid]?.append(tempMessage)
            self.sessionsUpdatePublisher.send()
            print("➕ Added temp chat message: \(message)")
        }
        
        let msg: [String: Any] = [
            "type": "chat",
            "message": message,
            "targetSession": session_uuid,
            "timestamp": timestamp
        ]
        
        send(dictionary: msg)
    }
    
    func sendFile(fileURL: URL) {
        guard let session_uuid = currentMessageSessionUUID else {
            print("❌ No active session")
            return
        }
        
        let fileName = fileURL.lastPathComponent
        let timestamp = nowMs()
        print("📤 Starting file upload: \(fileName)")
        print("📤 Upload URL: \(uploadURL.absoluteString)")
        
        let tempMessageId = UUID()
        let tempMessage = Message(
            id: tempMessageId,
            from: "iOSAdmin",
            to: "",
            type: "file",
            message: "Загрузка...",
            fileName: fileName,
            fileUrl: nil,
            timestamp: timestamp,
            callDuration: nil
        )
        
        // ИСПРАВЛЕНО: Используем timestamp и fileName для ключа
        let messageKey = "\(session_uuid)_\(timestamp)_\(fileName)"
        tempMessages[messageKey] = tempMessageId
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.sessions[session_uuid] == nil {
                self.sessions[session_uuid] = []
            }
            self.sessions[session_uuid]?.append(tempMessage)
            self.sessionsUpdatePublisher.send()
            print("➕ Added temp message for upload: \(fileName)")
        }
        
        uploadFile(fileURL: fileURL) { [weak self] result in
            guard let self = self else { return }
            
            let messageKey = "\(session_uuid)_\(timestamp)_\(fileName)"
            
            switch result {
            case .success(let fileInfo):
                print("✅ File uploaded successfully: \(fileInfo.fileName)")
                print("📎 File URL: \(fileInfo.fileUrl)")
                
                // Удаляем временное сообщение с загрузкой
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let tempMessageId = self.tempMessages[messageKey],
                       let sessionMessages = self.sessions[session_uuid],
                       let index = sessionMessages.firstIndex(where: { $0.id == tempMessageId }) {
                        self.sessions[session_uuid]?.remove(at: index)
                        print("➖ Removed temp message: \(fileName)")
                        self.tempMessages.removeValue(forKey: messageKey)
                    }
                    
                    // Добавляем финальное сообщение с файлом
                    let finalMsg = Message(
                        id: UUID(),
                        from: "iOSAdmin",
                        to: "",
                        type: "file",
                        message: nil,
                        fileName: fileInfo.fileName,
                        fileUrl: fileInfo.fileUrl,
                        timestamp: timestamp,
                        callDuration: nil
                    )
                    
                    self.sessions[session_uuid]?.append(finalMsg)
                    self.sessionsUpdatePublisher.send()
                    print("✅ Added final file message locally: \(fileInfo.fileName)")
                }
                
                let finalMessage: [String: Any] = [
                    "type": "file",
                    "fileName": fileInfo.fileName,
                    "fileUrl": fileInfo.fileUrl,
                    "mimeType": fileInfo.mimeType,
                    "size": fileInfo.size,
                    "targetSession": session_uuid,
                    "timestamp": timestamp
                ]
                
                self.send(dictionary: finalMessage)
                
            case .failure(let error):
                print("❌ File upload failed: \(error.localizedDescription)")
                
                // Удаляем временное сообщение с загрузкой
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let tempMessageId = self.tempMessages[messageKey],
                       let sessionMessages = self.sessions[session_uuid],
                       let index = sessionMessages.firstIndex(where: { $0.id == tempMessageId }) {
                        self.sessions[session_uuid]?.remove(at: index)
                        print("➖ Removed temp message: \(fileName)")
                        self.tempMessages.removeValue(forKey: messageKey)
                    }
                    
                    // Добавляем сообщение об ошибке
                    let errorMessage = Message(
                        id: UUID(),
                        from: "iOSAdmin",
                        to: "",
                        type: "file",
                        message: "Ошибка загрузки: \(error.localizedDescription)",
                        fileName: fileName,
                        fileUrl: nil,
                        timestamp: timestamp,
                        callDuration: nil
                    )
                    
                    self.sessions[session_uuid]?.append(errorMessage)
                    self.sessionsUpdatePublisher.send()
                    print("⚠️ Added error message for failed upload: \(fileName)")
                }
            }
        }
    }
    
    // НОВЫЙ МЕТОД: sendCallLogMessage
    func sendCallLogMessage(sessionUUID: String, duration: Int) {
        let timestamp = nowMs()
        
        let callLogMessage: [String: Any] = [
            "type": "call_log",
            "from": "system",
            "to": "all",
            "message": "Звонок завершен",
            "callDuration": duration,
            "session_uuid": sessionUUID,
            "timestamp": timestamp
        ]
        
        // Отправляем на сервер
        send(dictionary: callLogMessage)
        
        // Добавляем локально в сессию
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let logMessage = Message(
                id: UUID(),
                from: "system",
                to: "",
                type: "call_log",
                message: "Звонок завершен",
                fileName: nil,
                fileUrl: nil,
                timestamp: timestamp,
                callDuration: duration
            )
            
            if self.sessions[sessionUUID] == nil {
                self.sessions[sessionUUID] = []
            }
            
            self.sessions[sessionUUID]?.append(logMessage)
            self.sessionsUpdatePublisher.send()
            
            print("📞 Call log added: duration \(duration)s")
        }
    }
    
    // ИСПРАВЛЕННЫЙ МЕТОД: Запрос статуса веб-клиента с защитой от частых запросов
    func requestClientStatus(for sessionUUID: String) {
        let now = Date()
        
        // Проверяем, когда был последний запрос для этой сессии
        if let lastRequest = lastClientStatusRequest[sessionUUID] {
            if now.timeIntervalSince(lastRequest) < 5 { // Не чаще чем раз в 5 секунд
                print("⏱️ Too frequent request for session \(sessionUUID), skipping")
                return
            }
        }
        
        lastClientStatusRequest[sessionUUID] = now
        
        let request: [String: Any] = [
            "type": "get_client_status",
            "session_uuid": sessionUUID
        ]
        send(dictionary: request)
        print("📤 Requested client status for session: \(sessionUUID)")
    }
    
    // ИСПРАВЛЕНО: Используем динамический uploadURL
    private func uploadFile(fileURL: URL, completion: @escaping (Result<FileUploadInfo, Error>) -> Void) {
        print("📤 Uploading file: \(fileURL.lastPathComponent)")
        print("📤 Using upload URL: \(uploadURL.absoluteString)")
        
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalCacheData
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        let filename = fileURL.lastPathComponent
        let mimeType = self.mimeType(for: fileURL)
        
        print("📄 File info: \(filename), MIME: \(mimeType)")
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        
        do {
            let fileData = try Data(contentsOf: fileURL)
            print("📊 File size: \(fileData.count) bytes")
            body.append(fileData)
        } catch {
            print("❌ Error reading file: \(error)")
            completion(.failure(error))
            return
        }
        
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        let task = urlSession.uploadTask(with: request, from: body) { [weak self] respData, response, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ Upload network error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ Invalid response - no HTTP response")
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "UploadError", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "Неверный ответ сервера"
                    ])))
                }
                return
            }
            
            print("📡 Response status: \(httpResponse.statusCode)")
            
            if httpResponse.statusCode == 404 {
                print("❌ Endpoint not found (404)")
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "UploadError", code: 404, userInfo: [
                        NSLocalizedDescriptionKey: "Сервер загрузки не найден (404). Проверьте адрес сервера."
                    ])))
                }
                return
            }
            
            if httpResponse.statusCode == 413 {
                print("❌ File too large (413)")
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "UploadError", code: 413, userInfo: [
                        NSLocalizedDescriptionKey: "Файл слишком большой"
                    ])))
                }
                return
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                print("❌ Server error: \(httpResponse.statusCode)")
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "UploadError", code: httpResponse.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: "Ошибка сервера: \(httpResponse.statusCode)"
                    ])))
                }
                return
            }
            
            guard let respData = respData else {
                print("❌ No data received")
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "UploadError", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "Сервер не вернул данные"
                    ])))
                }
                return
            }
            
            if let rawResponse = String(data: respData, encoding: .utf8) {
                print("📥 Raw server response: \(rawResponse)")
            }
            
            do {
                guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
                    print("❌ Invalid JSON response")
                    DispatchQueue.main.async {
                        completion(.failure(NSError(domain: "UploadError", code: -1, userInfo: [
                            NSLocalizedDescriptionKey: "Неверный формат ответа сервера"
                        ])))
                    }
                    return
                }
                
                print("✅ Parsed JSON response: \(json)")
                
                if let errorMessage = json["error"] as? String {
                    print("❌ Server returned error: \(errorMessage)")
                    DispatchQueue.main.async {
                        completion(.failure(NSError(domain: "UploadError", code: -1, userInfo: [
                            NSLocalizedDescriptionKey: errorMessage
                        ])))
                    }
                    return
                }
                
                let fileName = json["fileName"] as? String ?? filename
                
                // ИСПРАВЛЕНО: Формируем правильный URL для файла
                let fileUrl: String
                if let urlFromJson = json["fileUrl"] as? String {
                    // Если сервер вернул полный URL, используем его
                    fileUrl = urlFromJson
                } else if let urlFromJson = json["url"] as? String {
                    fileUrl = urlFromJson
                } else {
                    // Иначе формируем из baseURL
                    fileUrl = "\(self.baseURL)/uploads/\(filename)"
                }
                
                let mimeType = json["mimeType"] as? String ?? json["type"] as? String ?? self.mimeType(for: fileURL)
                
                let size: Int
                if let sizeValue = json["size"] as? Int {
                    size = sizeValue
                } else if let sizeString = json["size"] as? String, let sizeInt = Int(sizeString) {
                    size = sizeInt
                } else {
                    do {
                        let fileData = try Data(contentsOf: fileURL)
                        size = fileData.count
                    } catch {
                        size = 0
                    }
                }
                
                let fileInfo = FileUploadInfo(
                    fileName: fileName,
                    fileUrl: fileUrl,
                    mimeType: mimeType,
                    size: size
                )
                
                print("✅ File info: \(fileInfo)")
                DispatchQueue.main.async {
                    completion(.success(fileInfo))
                }
                
            } catch {
                print("❌ JSON parsing error: \(error)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
        
        task.resume()
        print("📤 Upload task started")
    }
    
    private func mimeType(for url: URL) -> String {
        if #available(iOS 14.0, *) {
            if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
                return type.preferredMIMEType ?? "application/octet-stream"
            }
        } else {
            let ext = url.pathExtension as CFString
            if let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, ext, nil)?.takeRetainedValue(),
               let mime = UTTypeCopyPreferredTagWithClass(uti, kUTTagClassMIMEType)?.takeRetainedValue() {
                return mime as String
            }
        }
        
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "txt": return "text/plain"
        case "zip", "rar", "7z": return "application/zip"
        case "mp3", "wav", "ogg", "m4a": return "audio/mpeg"
        case "mp4", "avi", "mov", "mkv", "webm": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
    
    // ИСПРАВЛЕНО: downloadFile с динамическим baseURL
    func downloadFile(msg: Message) {
        guard var fileUrlStr = msg.fileUrl else {
            print("❌ Invalid file URL")
            showErrorAlert(message: "Неверный URL файла")
            return
        }
        
        // Если URL не полный (относительный), формируем полный из baseURL
        if !fileUrlStr.hasPrefix("http") && !fileUrlStr.hasPrefix("https") {
            if fileUrlStr.hasPrefix("/") {
                fileUrlStr = "\(baseURL)\(fileUrlStr)"
            } else {
                fileUrlStr = "\(baseURL)/uploads/\(fileUrlStr)"
            }
        }
        
        guard let url = URL(string: fileUrlStr) else {
            print("❌ Invalid file URL: \(fileUrlStr)")
            showErrorAlert(message: "Неверный URL файла")
            return
        }
        
        print("📥 Starting download from: \(url.absoluteString)")
        
        let task = urlSession.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self = self else { return }
            
            guard let tempURL = tempURL, error == nil else {
                print("❌ Download error: \(error?.localizedDescription ?? "Unknown error")")
                DispatchQueue.main.async {
                    self.showErrorAlert(message: error?.localizedDescription ?? "Неизвестная ошибка")
                }
                return
            }
            
            let originalFileName = msg.fileName ?? url.lastPathComponent
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            
            let fileNameWithExt: String
            if (originalFileName as NSString).pathExtension.isEmpty {
                let mimeType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
                let ext = self.extensionFromMimeType(mimeType) ?? self.extensionFromURL(url)
                fileNameWithExt = "\(originalFileName).\(ext)"
            } else {
                fileNameWithExt = originalFileName
            }
            
            let destinationURL = documentsPath.appendingPathComponent(fileNameWithExt)
            
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
                    let timestamp = dateFormatter.string(from: Date())
                    let nameWithoutExt = (fileNameWithExt as NSString).deletingPathExtension
                    let ext = (fileNameWithExt as NSString).pathExtension
                    let newFileName = ext.isEmpty ? "\(nameWithoutExt)_\(timestamp)" : "\(nameWithoutExt)_\(timestamp).\(ext)"
                    let newDestinationURL = documentsPath.appendingPathComponent(newFileName)
                    try FileManager.default.moveItem(at: tempURL, to: newDestinationURL)
                    print("✅ File saved as: \(newFileName)")
                    
                    DispatchQueue.main.async {
                        self.showSaveSuccessAlert(fileName: newFileName, fileURL: newDestinationURL)
                    }
                } else {
                    try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                    print("✅ File saved as: \(fileNameWithExt)")
                    
                    DispatchQueue.main.async {
                        self.showSaveSuccessAlert(fileName: fileNameWithExt, fileURL: destinationURL)
                    }
                }
            } catch {
                print("❌ Error saving file: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.showErrorAlert(message: "Ошибка сохранения файла: \(error.localizedDescription)")
                }
            }
        }
        task.resume()
    }
    
    private func extensionFromMimeType(_ mimeType: String) -> String? {
        switch mimeType {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "application/pdf": return "pdf"
        case "application/msword": return "doc"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return "docx"
        case "application/vnd.ms-excel": return "xls"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": return "xlsx"
        case "text/plain": return "txt"
        case "application/zip": return "zip"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        default: return nil
        }
    }
    
    private func extensionFromURL(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty {
            return ext
        }
        return "dat"
    }
    
    private func showSaveSuccessAlert(fileName: String, fileURL: URL) {
        DispatchQueue.main.async {
            let alert = UIAlertController(
                title: "Файл сохранен",
                message: "Файл \"\(fileName)\" сохранен в папку Документы",
                preferredStyle: .alert
            )
            
            alert.addAction(UIAlertAction(title: "Поделиться", style: .default) { _ in
                let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                if let root = UIApplication.shared.windows.first?.rootViewController {
                    if let popover = activityVC.popoverPresentationController {
                        popover.sourceView = root.view
                        popover.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
                        popover.permittedArrowDirections = []
                    }
                    root.present(activityVC, animated: true)
                }
            })
            
            alert.addAction(UIAlertAction(title: "Открыть", style: .default) { _ in
                UIApplication.shared.open(fileURL)
            })
            
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            
            if let root = UIApplication.shared.windows.first?.rootViewController {
                root.present(alert, animated: true)
            }
        }
    }
    
    private func showErrorAlert(message: String) {
        DispatchQueue.main.async {
            let alert = UIAlertController(
                title: "Ошибка",
                message: message,
                preferredStyle: .alert
            )
            
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            
            if let root = UIApplication.shared.windows.first?.rootViewController {
                root.present(alert, animated: true)
            }
        }
    }
    
    func send(dictionary: [String: Any], skipDuplicateCheck: Bool = false) {
        guard let task = webSocketTask else {
            print("❌ Cannot send: WebSocket not connected")
            return
        }
        
        if !skipDuplicateCheck, let type = dictionary["type"] as? String, type == "register" {
            if isConnected && reconnectionAttempts == 0 {
                print("⚠️ Skipping duplicate register, already connected")
                return
            }
        }
        
        do {
            let data = try JSONSerialization.data(withJSONObject: dictionary)
            if let str = String(data: data, encoding: .utf8) {
                print("📤 Sending via WebSocket: \(str.prefix(100))...")
                task.send(.string(str)) { [weak self] error in
                    guard let self = self else { return }
                    if let error = error {
                        let nsError = error as NSError
                        print("❌ WebSocket send error: \(error.localizedDescription), code: \(nsError.code)")
                        
                        if nsError.code == 57 || nsError.code == 89 {
                            DispatchQueue.main.async {
                                self.isConnected = false
                                if self.shouldReconnect {
                                    self.reconnect()
                                }
                            }
                        }
                    } else {
                        print("✅ Message sent successfully via WebSocket")
                    }
                }
            }
        } catch {
            print("❌ JSON serialization error: \(error)")
        }
    }
    
    // MARK: - Управление архивом
    private func saveArchivedSessions() {
        UserDefaults.standard.set(archivedSessions, forKey: archivedSessionsKey)
        print("💾 Сохранено \(archivedSessions.count) архивных сессий в UserDefaults")
    }
    
    private func loadArchivedSessions() {
        if let saved = UserDefaults.standard.array(forKey: archivedSessionsKey) as? [String] {
            archivedSessions = saved
            print("📦 Загружено \(saved.count) архивных сессий из UserDefaults")
        }
    }
}

struct FileUploadInfo {
    let fileName: String
    let fileUrl: String
    let mimeType: String
    let size: Int
}

struct Message: Identifiable, Equatable {
    var id = UUID()
    var from: String
    var to: String
    var type: String
    var message: String?
    var fileName: String?
    var fileUrl: String?
    var timestamp: Int64
    var callDuration: Int? // Добавлено для логов звонков

    // Добавляем метод для определения типа сообщения
    var isSystemMessage: Bool {
        return from == "system"
    }
    
    var isCallLogMessage: Bool {
        return from == "system" && type == "call_log"
    }
    
    // Форматированное сообщение о звонке
    var callLogText: String {
        guard isCallLogMessage, let duration = callDuration else { return message ?? "" }
        
        let minutes = duration / 60
        let seconds = duration % 60
        
        if minutes > 0 {
            return "📞 Звонок длился \(minutes) мин \(seconds) сек"
        } else {
            return "📞 Звонок длился \(seconds) сек"
        }
    }
    
    static func from(dict: [String: Any]) -> Message? {
        guard let from = dict["from"] as? String,
              let to = dict["to"] as? String,
              let type = dict["type"] as? String else { return nil }

        let ts: Int64
        if let t = dict["timestamp"] as? Int64 {
            // АВТОМАТИЧЕСКОЕ ОПРЕДЕЛЕНИЕ ФОРМАТА TIMESTAMP
            // Проверяем количество цифр:
            let digitCount = String(t).count
            
            switch digitCount {
            case 1...10: // 1-10 цифр = секунды (до 2286 года)
                print("📱 Detected seconds timestamp: \(t) -> converting to milliseconds")
                ts = t * 1000
            case 11...13: // 11-13 цифр = миллисекунды (корректный формат)
                print("📱 Detected milliseconds timestamp: \(t)")
                ts = t
            case 14...16: // 14-16 цифр = микросекунды
                print("📱 Detected microseconds timestamp: \(t) -> converting to milliseconds")
                ts = t / 1000
            default: // Неизвестный формат
                print("⚠️ Unknown timestamp format: \(t) digits, using current time")
                ts = Int64(Date().timeIntervalSince1970 * 1000)
            }
            
            // ДЛЯ ОТЛАДКИ: Выводим что получилось
            let date = Date(timeIntervalSince1970: Double(ts) / 1000)
            let formatter = DateFormatter()
            formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
            print("📅 Parsed timestamp \(ts) as: \(formatter.string(from: date))")
            
        } else {
            ts = Int64(Date().timeIntervalSince1970 * 1000)
        }

        return Message(
            id: UUID(),
            from: from,
            to: to,
            type: type,
            message: dict["message"] as? String ?? dict["fileData"] as? String,
            fileName: dict["fileName"] as? String,
            fileUrl: dict["fileUrl"] as? String,
            timestamp: ts,
            callDuration: dict["callDuration"] as? Int
        )
    }
}
