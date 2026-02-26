import UIKit
import AVFoundation
import UserNotifications
import BackgroundTasks
import PushKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    
    // Менеджеры
    private let callSoundManager = CallSoundManager.shared
    private let webRTCManager = WebRTCManager.shared
    
    // Добавляем PushKit регистрацию
    private var pushRegistry: PKPushRegistry?
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        
        print("🚀 App launching...")
        
        // 1. Настройка аудиосессии для звонков
        setupAudioSession()
        
        // 2. Регистрация для VoIP пушей (ВАЖНО!)
        setupPushKit()
        
        // 3. Регистрация для обычных Push-уведомлений
        registerForPushNotifications(application: application)
        
        // 4. Настройка фоновых задач
        setupBackgroundTasks()
        
        // 5. Восстановление соединения при запуске
        restoreConnectionIfNeeded()
        
        // 6. Настройка наблюдателей для звонков
        setupCallObservers()
        
        // 7. Настройка наблюдателя для принудительного сброса после видеозвонка
        setupCallCleanupObserver()
        
        // 8. Проверяем, не запущено ли приложение из звонка
        if let options = launchOptions {
            if options[.remoteNotification] != nil {
                print("📱 App launched from push notification")
            }
        }
        
        return true
    }
    
    // MARK: - PushKit Registration (КРИТИЧЕСКИ ВАЖНО ДЛЯ ЗВОНКОВ)
    
    private func setupPushKit() {
        print("📱 Setting up PushKit for VoIP")
        
        pushRegistry = PKPushRegistry(queue: .main)
        pushRegistry?.delegate = self
        pushRegistry?.desiredPushTypes = [.voIP]
    }
    
    // MARK: - Настройка наблюдателей для звонков
    
    private func setupCallObservers() {
        // Наблюдаем за состоянием звонка
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIncomingCall),
            name: NSNotification.Name("IncomingCallNotification"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCallStateChanged),
            name: NSNotification.Name("CallStateChangedNotification"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCallAccepted),
            name: NSNotification.Name("CallAcceptedNotification"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCallEnded),
            name: NSNotification.Name("CallEndedNotification"),
            object: nil
        )
        
        // Наблюдаем за состоянием соединения
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConnectionStateChanged),
            name: NSNotification.Name("WebSocketConnectionChanged"),
            object: nil
        )
        
        print("📞 Call observers setup complete")
    }
    
    // НОВЫЙ МЕТОД: Наблюдатель для изменения соединения
    @objc private func handleConnectionStateChanged(_ notification: Notification) {
        let isConnected = notification.userInfo?["isConnected"] as? Bool ?? false
        print("📱 WebSocket connection state changed: \(isConnected)")
        
        if !isConnected {
            // Пытаемся переподключиться
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                WebSocketService.shared.connect()
            }
        }
    }
    
    // НОВЫЙ МЕТОД: Наблюдатель для принудительного сброса после видеозвонка
    private func setupCallCleanupObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVideoCallCleanup),
            name: NSNotification.Name("VideoCallEndedNotification"),
            object: nil
        )
    }
    
    @objc private func handleIncomingCall(_ notification: Notification) {
        print("📞 AppDelegate: Incoming call detected")
        
        // Получаем информацию о звонке
        let userInfo = notification.userInfo ?? [:]
        let hasVideo = userInfo["hasVideo"] as? Bool ?? false
        let callerName = userInfo["from"] as? String ?? "Клиент"
        let callId = userInfo["callId"] as? String ?? ""
        let sessionUUID = userInfo["sessionUUID"] as? String ?? ""
        
        // Убеждаемся что WebSocket подключен
        if !WebSocketService.shared.isConnected {
            print("⚠️ WebSocket not connected when call received, reconnecting...")
            WebSocketService.shared.connect()
        }
        
        // Устанавливаем badge для привлечения внимания
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber += 1
        }
        
        // Если приложение в фоне, показываем уведомление как запасной вариант
        if UIApplication.shared.applicationState == .background {
            showIncomingCallNotification(callerName: callerName, hasVideo: hasVideo)
        }
    }
    
    @objc private func handleCallStateChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let stateValue = userInfo["state"] as? Int else { return }
        
        switch stateValue {
        case 1: // incoming
            print("📞 Call state: incoming")
        case 2: // connecting
            print("📞 Call state: connecting")
            callSoundManager.stopRinging()
        case 3: // connected
            print("📞 Call state: connected")
            callSoundManager.stopRinging()
            callSoundManager.playCallConnected()
            
            // Сбрасываем badge
            DispatchQueue.main.async {
                UIApplication.shared.applicationIconBadgeNumber = 0
            }
        case 0: // idle
            print("📞 Call state: idle")
            callSoundManager.stopRinging()
        default:
            break
        }
    }
    
    @objc private func handleCallAccepted(_ notification: Notification) {
        print("📞 AppDelegate: Call accepted")
        
        callSoundManager.stopRinging()
        callSoundManager.playCallConnected()
        
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }
    
    // ИСПРАВЛЕНО: handleCallEnded с принудительным сбросом после видеозвонка
    @objc private func handleCallEnded(_ notification: Notification) {
        print("📞 AppDelegate: Call ended")
        
        callSoundManager.stopRinging()
        callSoundManager.playCallEnded()
        
        // Проверяем, был ли это видеозвонок
        let hadVideo = notification.userInfo?["hadVideo"] as? Bool ?? false
        
        if hadVideo {
            print("🎥 Video call ended - performing deep cleanup")
            performVideoCallCleanup()
        }
        
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }
    
    // НОВЫЙ МЕТОД: Обработка принудительного сброса после видеозвонка
    @objc private func handleVideoCallCleanup(_ notification: Notification) {
        print("🎥 AppDelegate: Performing video call cleanup")
        performVideoCallCleanup()
    }
    
    // НОВЫЙ МЕТОД: Полный сброс после видеозвонка
    private func performVideoCallCleanup() {
        print("🧹 AppDelegate: Starting video call deep cleanup")
        
    
        
        // 2. Даем время на обработку
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            // Временно отключаем, так как метод отсутствует
            // self?.webRTCManager.prepareForNewCall()
            // Вместо этого просто сбрасываем аудио
            self?.webRTCManager.endCall()
            self?.resetAudioSessionCompletely()
            
            // 4. Переконфигурируем аудиосессию
            self?.resetAudioSessionCompletely()
            
            // 5. Перерегистрируемся в VoIP (ВАЖНО!)
            self?.pushRegistry = PKPushRegistry(queue: .main)
            self?.pushRegistry?.delegate = self
            self?.pushRegistry?.desiredPushTypes = [.voIP]
            
            print("✅ AppDelegate: Video call cleanup completed")
        }
    }
    
    // НОВЫЙ МЕТОД: Полный сброс аудиосессии
    private func resetAudioSessionCompletely() {
        print("🔊 AppDelegate: Resetting audio session completely")
        
        let session = AVAudioSession.sharedInstance()
        
        // Деактивируем
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            print("🔇 Audio session deactivated")
        } catch {
            print("❌ Failed to deactivate audio session: \(error)")
        }
        
        // Небольшая задержка
        Thread.sleep(forTimeInterval: 0.1)
        
        // Активируем заново с правильными настройками
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
            )
            try session.setActive(true)
            print("🔊 Audio session reconfigured and activated")
        } catch {
            print("❌ Failed to reconfigure audio session: \(error)")
        }
    }
    
    private func showIncomingCallNotification(callerName: String, hasVideo: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = hasVideo ? "📹 Входящий видеозвонок" : "📞 Входящий звонок"
        content.body = "\(callerName) звонит вам"
        content.sound = .default
        content.categoryIdentifier = "CALL_CATEGORY"
        content.userInfo = [
            "type": "call",
            "callerName": callerName,
            "hasVideo": hasVideo,
            "timestamp": Date().timeIntervalSince1970
        ]
        content.badge = 1
        
        let request = UNNotificationRequest(
            identifier: "incoming_call_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to show call notification: \(error)")
            }
        }
    }
    
    // MARK: - Фоновая работа
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        print("✅ App became active")
        
        UIApplication.shared.applicationIconBadgeNumber = 0
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !WebSocketService.shared.isConnected {
                print("🔄 App became active but not connected, reconnecting...")
                WebSocketService.shared.connect()
            }
        }
    }
    
    func applicationWillResignActive(_ application: UIApplication) {
        print("📱 App will resign active")
        saveAppState()
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        print("📱 App entered background")
        saveAppState()
        scheduleBackgroundRefresh()
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        print("📱 App entered foreground")
        restoreConnection()
        
        // Проверяем состояние аудио при возвращении из фона
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.checkAudioSessionState()
        }
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        print("📱 App will terminate")
        saveAppState()
        
       
        
        WebSocketService.shared.disconnect()
    }
    
    // НОВЫЙ МЕТОД: Проверка состояния аудиосессии
    private func checkAudioSessionState() {
        let session = AVAudioSession.sharedInstance()
        print("🔊 Current audio session state:")
        print("   - Category: \(session.category.rawValue)")
        print("   - Mode: \(session.mode.rawValue)")
        print("   - Is active: \(session.isOtherAudioPlaying ? "playing" : "inactive")")
        
        // Если сессия не активна, но приложение должно быть готово к звонкам
        if !session.isOtherAudioPlaying && webRTCManager.callState == .idle {
            print("🔊 Audio session inactive, reconfiguring...")
            resetAudioSessionCompletely()
        }
    }
    
    // MARK: - Уведомления
    
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("📱 Device token: \(token)")
        UserDefaults.standard.set(token, forKey: "devicePushToken")
    }
    
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("❌ Failed to register for remote notifications: \(error)")
    }
    
    // MARK: - Приватные методы
    
    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            print("🔊 AudioSession ready for calls")
        } catch {
            print("❌ AudioSession error:", error)
        }
    }
    
    private func registerForPushNotifications(application: UIApplication) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        
        let options: UNAuthorizationOptions = [.alert, .sound, .badge]
        
        center.requestAuthorization(options: options) { granted, error in
            if let error = error {
                print("❌ Notification permission error: \(error)")
                return
            }
            
            print("📱 Notification permission granted: \(granted)")
            
            if granted {
                DispatchQueue.main.async {
                    application.registerForRemoteNotifications()
                }
            }
        }
        
        // Настраиваем категории
        setupNotificationCategories()
    }
    
    private func setupNotificationCategories() {
        let answerAction = UNNotificationAction(
            identifier: "ANSWER_CALL_ACTION",
            title: "Ответить",
            options: [.foreground]
        )
        
        let declineAction = UNNotificationAction(
            identifier: "DECLINE_CALL_ACTION",
            title: "Отклонить",
            options: [.destructive]
        )
        
        let callCategory = UNNotificationCategory(
            identifier: "CALL_CATEGORY",
            actions: [answerAction, declineAction],
            intentIdentifiers: [],
            options: []
        )
        
        UNUserNotificationCenter.current().setNotificationCategories([callCategory])
    }
    
    private func setupBackgroundTasks() {
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: "com.otvetdz.refresh",
                using: nil
            ) { task in
                self.handleBackgroundRefresh(task: task as! BGAppRefreshTask)
            }
            print("✅ Background tasks registered")
        }
    }
    
    private func scheduleBackgroundRefresh() {
        if #available(iOS 13.0, *) {
            let request = BGAppRefreshTaskRequest(identifier: "com.otvetdz.refresh")
            request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            
            do {
                try BGTaskScheduler.shared.submit(request)
                print("✅ Background refresh scheduled")
            } catch {
                print("❌ Could not schedule background refresh: \(error)")
            }
        }
    }
    
    @available(iOS 13.0, *)
    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        
        if !WebSocketService.shared.isConnected {
            WebSocketService.shared.connect()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            task.setTaskCompleted(success: true)
            self.scheduleBackgroundRefresh()
        }
    }
    
    private func restoreConnectionIfNeeded() {
        restoreAppState()
        
        // Немедленно пытаемся подключиться при запуске
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !WebSocketService.shared.isConnected {
                print("🔄 Restoring WebSocket connection on launch")
                WebSocketService.shared.connect()
            }
        }
    }
    
    private func restoreConnection() {
        if !WebSocketService.shared.isConnected {
            print("🔄 Restoring WebSocket connection after background")
            WebSocketService.shared.connect()
        }
    }
    
    private func saveAppState() {
        UserDefaults.standard.set(
            WebSocketService.shared.currentMessageSessionUUID,
            forKey: "lastActiveSessionUUID"
        )
        UserDefaults.standard.set(
            Date().timeIntervalSince1970,
            forKey: "lastBackgroundTime"
        )
        UserDefaults.standard.synchronize()
    }
    
    private func restoreAppState() {
        if let lastSession = UserDefaults.standard.string(forKey: "lastActiveSessionUUID") {
            DispatchQueue.main.async {
                WebSocketService.shared.currentMessageSessionUUID = lastSession
                WebSocketService.shared.currentCallSessionUUID = lastSession
                print("📱 Restored last session: \(lastSession)")
            }
        }
    }
}

// MARK: - PKPushRegistryDelegate (КРИТИЧЕСКИ ВАЖНО ДЛЯ VoIP ЗВОНКОВ)
extension AppDelegate: PKPushRegistryDelegate {
    
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let deviceToken = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        print("📱 VoIP Push Token: \(deviceToken)")
        
        // Сохраняем токен и отправляем на сервер
        UserDefaults.standard.set(deviceToken, forKey: "voipPushToken")
        
        // Отправляем токен на ваш сервер
        let payload: [String: Any] = [
            "type": "register_voip",
            "token": deviceToken,
            "platform": "ios"
        ]
        WebSocketService.shared.send(dictionary: payload)
    }
    
    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        print("📱 VoIP Push Token invalidated")
        UserDefaults.standard.removeObject(forKey: "voipPushToken")
    }
    
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        print("📱 Received VoIP push: \(payload.dictionaryPayload)")
        
        // Обрабатываем входящий VoIP пуш
        if type == .voIP {
            // Извлекаем данные звонка из payload
            if let callData = payload.dictionaryPayload as? [String: Any] {
                handleIncomingVoIPPush(callData)
            }
        }
        
        completion()
    }
    
    private func handleIncomingVoIPPush(_ callData: [String: Any]) {
        print("📞 Processing VoIP push data: \(callData)")
        
        // Извлекаем информацию о звонке
        let sessionUUID = callData["session_uuid"] as? String ?? UUID().uuidString
        let callId = callData["callId"] as? String ?? UUID().uuidString
        let callerName = callData["from"] as? String ?? "Клиент"
        let hasVideo = callData["hasVideo"] as? Bool ?? false
        
        // Убеждаемся что WebSocket подключен
        if !WebSocketService.shared.isConnected {
            WebSocketService.shared.connect()
        }
        
       
        
        // Также отправляем уведомление в приложение
        NotificationCenter.default.post(
            name: NSNotification.Name("IncomingCallNotification"),
            object: nil,
            userInfo: [
                "callId": callId,
                "sessionUUID": sessionUUID,
                "from": callerName,
                "hasVideo": hasVideo,
                "timestamp": Date().timeIntervalSince1970
            ]
        )
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension AppDelegate: UNUserNotificationCenterDelegate {
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        print("📱 Notification received in foreground: \(userInfo)")
        
        // Не показываем уведомления в активном приложении
        completionHandler([])
    }
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionIdentifier = response.actionIdentifier
        
        print("📱 Notification action: \(actionIdentifier)")
        
        switch actionIdentifier {
        case "ANSWER_CALL_ACTION":
            // При ответе через уведомление - открываем приложение
            if let sessionUUID = userInfo["session_uuid"] as? String {
                NotificationCenter.default.post(
                    name: NSNotification.Name("OpenChatNotification"),
                    object: nil,
                    userInfo: ["sessionUUID": sessionUUID]
                )
            }
            
        case "DECLINE_CALL_ACTION":
            print("📞 Call declined from notification")
            
        case UNNotificationDefaultActionIdentifier:
            if let sessionUUID = userInfo["session_uuid"] as? String {
                NotificationCenter.default.post(
                    name: NSNotification.Name("OpenChatNotification"),
                    object: nil,
                    userInfo: ["sessionUUID": sessionUUID]
                )
            }
            
        default:
            break
        }
        
        completionHandler()
    }
}
