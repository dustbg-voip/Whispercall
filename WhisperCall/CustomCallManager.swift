import Foundation
import AVFoundation
import WebRTC
import UIKit
import Combine
import MediaPlayer

// MARK: - Custom Call Manager (без CallKit)
final class CustomCallManager: NSObject, ObservableObject {
    static let shared = CustomCallManager()
    
    // WebRTC менеджер
    private let webRTCManager = WebRTCManager.shared
    
    // Состояние звонка
    @Published var callState: CallState = .idle {
        didSet {
            print("📞 Call state changed to: \(callState)")
            // При изменении состояния на idle или ended отправляем уведомление
            if callState == .idle || callState == .ended {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("CallShouldDismiss"),
                        object: nil
                    )
                }
            }
        }
    }
    @Published var isIncomingCall = false
    @Published var callerInfo: CallerInfo?
    @Published var callDuration: TimeInterval = 0
    
    // Информация об аудио устройствах
    @Published var availableAudioRoutes: [AudioRoute] = []
    @Published var currentAudioRoute: AudioRoute = .builtInSpeaker
    @Published var isBluetoothAvailable: Bool = false
    @Published var isHeadphonesAvailable: Bool = false
    
    // Таймер для длительности звонка
    private var callTimer: Timer?
    private var callStartTime: Date?
    private var lastUpdateTime: Date? // Для отслеживания реального времени
    
    // Для управления аудио сессией
    private let audioSession = AVAudioSession.sharedInstance()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    // Фоновый таймер для поддержания соединения
    private var backgroundTimer: Timer?
    
    // Наблюдатели
    private var routeChangeObserver: NSObjectProtocol?
    private var volumeObserver: NSKeyValueObservation?
    
    // Структура для информации о звонящем
    struct CallerInfo {
        let callId: String
        let sessionUUID: String
        let callerName: String
        let hasVideo: Bool
        let timestamp: TimeInterval
    }
    
    // Структура для аудио маршрутов
    enum AudioRoute: String, CaseIterable {
        case builtInSpeaker = "Динамик"
        case builtInReceiver = "Разговорный"
        case headphones = "Наушники"
        case bluetooth = "Bluetooth"
        case airPods = "AirPods"
        
        var icon: String {
            switch self {
            case .builtInSpeaker: return "speaker.wave.2.fill"
            case .builtInReceiver: return "iphone.radiowaves.left.and.right"
            case .headphones: return "headphones"
            case .bluetooth: return "airpodspro"
            case .airPods: return "airpodsmax"
            }
        }
        
        var priority: Int {
            switch self {
            case .airPods: return 100
            case .bluetooth: return 90
            case .headphones: return 80
            case .builtInSpeaker: return 70
            case .builtInReceiver: return 60
            }
        }
    }
    
    enum CallState: Int {
        case idle = 0
        case incoming = 1
        case outgoing = 2
        case connecting = 3
        case connected = 4
        case ended = 5
        
        var description: String {
            switch self {
            case .idle: return "Ожидание"
            case .incoming: return "Входящий"
            case .outgoing: return "Исходящий"
            case .connecting: return "Соединение"
            case .connected: return "Разговор"
            case .ended: return "Завершен"
            }
        }
        
        var color: String {
            switch self {
            case .incoming: return "green"
            case .outgoing, .connecting: return "blue"
            case .connected: return "purple"
            default: return "gray"
            }
        }
    }
    
    private override init() {
        super.init()
        setupAudioSession()
        setupNotifications()
        setupRouteObservers()
        setupVolumeObserver()
        print("📞 CustomCallManager initialized")
    }
    
    // MARK: - Настройка аудио сессии
    
    private func setupAudioSession() {
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay, .defaultToSpeaker, .mixWithOthers]
            )
            try audioSession.setActive(true)
            print("🔊 Audio session configured")
            
            // Обновляем доступные маршруты
            updateAvailableRoutes()
        } catch {
            print("❌ Failed to configure audio session: \(error)")
        }
    }
    
    private func activateAudioSession() {
        do {
            try audioSession.setActive(true)
            print("🔊 Audio session activated")
        } catch {
            print("❌ Failed to activate audio session: \(error)")
        }
    }
    
    private func deactivateAudioSession() {
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            print("🔇 Audio session deactivated")
        } catch {
            print("❌ Failed to deactivate audio session: \(error)")
        }
    }
    
    // MARK: - Настройка наблюдателей аудио
    
    private func setupRouteObservers() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleRouteChange()
        }
    }
    
    private func setupVolumeObserver() {
        volumeObserver = audioSession.observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            self?.objectWillChange.send()
        }
    }
    
    private func handleRouteChange() {
        updateAvailableRoutes()
        updateCurrentRoute()
        
        // Уведомляем об изменении маршрута
        NotificationCenter.default.post(
            name: NSNotification.Name("AudioRouteDidChange"),
            object: currentAudioRoute
        )
    }
    
    private func updateAvailableRoutes() {
        var routes: [AudioRoute] = []
        
        // Проверяем Bluetooth
        if isBluetoothDeviceConnected() {
            routes.append(.bluetooth)
            isBluetoothAvailable = true
        } else {
            isBluetoothAvailable = false
        }
        
        // Проверяем наушники
        if hasWiredHeadphones() {
            routes.append(.headphones)
            isHeadphonesAvailable = true
        } else {
            isHeadphonesAvailable = false
        }
        
        // Проверяем AirPods
        if hasAirPods() {
            routes.append(.airPods)
        }
        
        // Всегда доступны
        routes.append(.builtInSpeaker)
        routes.append(.builtInReceiver)
        
        // Сортируем по приоритету
        availableAudioRoutes = routes.sorted { $0.priority > $1.priority }
    }
    
    private func updateCurrentRoute() {
        let outputs = audioSession.currentRoute.outputs
        
        if let port = outputs.first {
            switch port.portType {
            case .builtInSpeaker:
                currentAudioRoute = .builtInSpeaker
            case .builtInReceiver:
                currentAudioRoute = .builtInReceiver
            case .headphones, .headsetMic:
                currentAudioRoute = .headphones
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
                currentAudioRoute = .bluetooth
            default:
                if port.portName.contains("AirPods") {
                    currentAudioRoute = .airPods
                } else {
                    currentAudioRoute = .builtInSpeaker
                }
            }
        }
    }
    
    private func isBluetoothDeviceConnected() -> Bool {
        let outputs = audioSession.currentRoute.outputs
        return outputs.contains { output in
            output.portType == .bluetoothA2DP ||
            output.portType == .bluetoothHFP ||
            output.portType == .bluetoothLE
        }
    }
    
    private func hasWiredHeadphones() -> Bool {
        let outputs = audioSession.currentRoute.outputs
        return outputs.contains { $0.portType == .headphones }
    }
    
    private func hasAirPods() -> Bool {
        let outputs = audioSession.currentRoute.outputs
        return outputs.contains { $0.portName.contains("AirPods") }
    }
    
    // MARK: - Управление аудио маршрутами
    
    func switchToSpeaker() {
        do {
            try audioSession.overrideOutputAudioPort(.speaker)
            print("🔊 Switched to speaker")
            updateCurrentRoute()
        } catch {
            print("❌ Failed to switch to speaker: \(error)")
        }
    }
    
    func switchToReceiver() {
        do {
            try audioSession.overrideOutputAudioPort(.none)
            print("📞 Switched to receiver")
            updateCurrentRoute()
        } catch {
            print("❌ Failed to switch to receiver: \(error)")
        }
    }
    
    func switchToBluetooth() {
        do {
            try audioSession.overrideOutputAudioPort(.none)
            print("📱 Switched to bluetooth")
            updateCurrentRoute()
        } catch {
            print("❌ Failed to switch to bluetooth: \(error)")
        }
    }
    
    func toggleAudioRoute() {
        if isBluetoothAvailable || isHeadphonesAvailable {
            if currentAudioRoute == .builtInSpeaker {
                // Если сейчас динамик, переключаем на Bluetooth/наушники
                switchToBluetooth()
            } else {
                // Иначе на динамик
                switchToSpeaker()
            }
        } else {
            // Если нет внешних устройств, переключаем между динамиком и разговорным
            if currentAudioRoute == .builtInSpeaker {
                switchToReceiver()
            } else {
                switchToSpeaker()
            }
        }
    }
    
    // MARK: - Громкость
    
    var currentVolume: Float {
        return audioSession.outputVolume
    }
    
    func setVolume(_ volume: Float) {
        let volumeView = MPVolumeView()
        if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            DispatchQueue.main.async {
                slider.value = volume
            }
        }
    }
    
    // MARK: - Настройка уведомлений
    
    private func setupNotifications() {
        // Наблюдаем за уведомлениями о звонках из WebRTCManager
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIncomingCallNotification),
            name: NSNotification.Name("IncomingCallNotification"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCallStateChanged),
            name: NSNotification.Name("CallStateChangedNotification"),
            object: nil
        )
        
        // Наблюдаем за переходом в фон/активный режим
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        // Наблюдаем за прерываниями (звонки, будильник и т.д.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }
    
    // MARK: - Обработка уведомлений
    
    @objc private func handleIncomingCallNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let callId = userInfo["callId"] as? String,
              let sessionUUID = userInfo["sessionUUID"] as? String,
              let from = userInfo["from"] as? String else { return }
        
        let hasVideo = userInfo["hasVideo"] as? Bool ?? false
        
        print("📞 CustomCallManager: Incoming call from \(from), video: \(hasVideo)")
        
        // ИСПРАВЛЕНО: Запускаем рингтон при входящем звонке
        CallSoundManager.shared.startRinging()
        
        // Создаем информацию о звонящем
        let caller = CallerInfo(
            callId: callId,
            sessionUUID: sessionUUID,
            callerName: from,
            hasVideo: hasVideo,
            timestamp: Date().timeIntervalSince1970
        )
        
        DispatchQueue.main.async { [weak self] in
            self?.callerInfo = caller
            self?.isIncomingCall = true
            self?.callState = .incoming
        }
        
        // Активируем аудио сессию для звонка
        activateAudioSession()
        
        // Показываем кастомный интерфейс входящего звонка
        showIncomingCallUI(callerInfo: caller)
    }
    
    @objc private func handleCallStateChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let stateValue = userInfo["state"] as? Int else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            switch stateValue {
            case 1: // incoming
                self.callState = .incoming
                
            case 2: // connecting
                self.callState = .connecting
                // ИСПРАВЛЕНО: Останавливаем рингтон при соединении
                CallSoundManager.shared.stopRinging()
                
            case 3: // connected
                self.callState = .connected
                
                // ВАЖНО: Запускаем таймер ТОЛЬКО если он еще не запущен
                if self.callTimer == nil {
                    self.startCallTimer()
                }
                
                self.isIncomingCall = false
                
                // Начинаем фоновую задачу для поддержания звонка
                self.startBackgroundTask()
                
            case 0: // idle
                self.callState = .idle
                self.stopCallTimer()
                self.isIncomingCall = false
                self.callerInfo = nil
                self.callDuration = 0
                
                // ИСПРАВЛЕНО: Останавливаем рингтон при завершении
                CallSoundManager.shared.stopRinging()
                
                // Завершаем фоновую задачу
                self.endBackgroundTask()
                
                // Деактивируем аудио
                self.deactivateAudioSession()
                
                // Отправляем уведомление о завершении
                NotificationCenter.default.post(
                    name: NSNotification.Name("CallEndedNotification"),
                    object: nil
                )
            default:
                break
            }
        }
    }
    
    // MARK: - Действия со звонком
    
    func acceptCall() {
        guard let callerInfo = callerInfo else {
            print("❌ No caller info to accept")
            return
        }
        
        print("📞 Accepting call from \(callerInfo.callerName)")
        
        // ИСПРАВЛЕНО: Останавливаем рингтон при ответе
        CallSoundManager.shared.stopRinging()
        
        DispatchQueue.main.async { [weak self] in
            self?.callState = .connecting
            self?.isIncomingCall = false
        }
        
        // Активируем аудио и отвечаем на звонок
        activateAudioSession()
        
        Task {
            await webRTCManager.answerCall(to: callerInfo.callerName)
        }
    }
    
    func declineCall() {
        guard let callerInfo = callerInfo else { return }
        
        print("📞 Declining call from \(callerInfo.callerName)")
        
        // ИСПРАВЛЕНО: Останавливаем рингтон при отклонении
        CallSoundManager.shared.stopRinging()
        
        // Отправляем отклонение
        let payload: [String: Any] = [
            "type": "call_reject",
            "callId": callerInfo.callId,
            "from": "iOSAdmin",
            "session_uuid": callerInfo.sessionUUID,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        WebSocketService.shared.send(dictionary: payload)
        
        // Очищаем состояние
        DispatchQueue.main.async { [weak self] in
            self?.callState = .idle
            self?.isIncomingCall = false
            self?.callerInfo = nil
            self?.callDuration = 0
        }
        
        // Деактивируем аудио
        deactivateAudioSession()
        
        // Отправляем уведомление о завершении
        NotificationCenter.default.post(
            name: NSNotification.Name("CallEndedNotification"),
            object: nil
        )
    }
    
    func startCall(sessionUUID: String, to peerName: String, withVideo: Bool = false) {
        print("📞 Starting call to \(peerName), video: \(withVideo)")
        
        DispatchQueue.main.async { [weak self] in
            self?.callState = .outgoing
            self?.callerInfo = CallerInfo(
                callId: UUID().uuidString,
                sessionUUID: sessionUUID,
                callerName: peerName,
                hasVideo: withVideo,
                timestamp: Date().timeIntervalSince1970
            )
        }
        
        // Активируем аудио
        activateAudioSession()
        
        // Начинаем звонок через WebRTC
        Task {
            await webRTCManager.startCall(sessionUUID: sessionUUID, to: peerName, withVideo: withVideo)
        }
    }
    
    func endCall() {
        print("📞 Ending current call")
        
        // ИСПРАВЛЕНО: Останавливаем рингтон при завершении
        CallSoundManager.shared.stopRinging()
        
        // Останавливаем таймер ДО завершения звонка
        stopCallTimer()
        
        // Завершаем через WebRTC
        webRTCManager.endCall()
        
        // Очищаем состояние на главном потоке
        DispatchQueue.main.async { [weak self] in
            self?.callState = .ended
            self?.isIncomingCall = false
            self?.callerInfo = nil
            // НЕ сбрасываем callDuration здесь, пусть отобразится финальное значение
            
            // Завершаем фоновую задачу
            self?.endBackgroundTask()
        }
        
        // Деактивируем аудио с задержкой
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.deactivateAudioSession()
        }
        
        // Отправляем уведомление о завершении
        NotificationCenter.default.post(
            name: NSNotification.Name("CallEndedNotification"),
            object: nil
        )
    }
    
    // MARK: - Таймер звонка (ИСПРАВЛЕННАЯ ВЕРСИЯ)
    
    private func startCallTimer() {
        print("⏱️ Starting call timer")
        
        // Останавливаем существующий таймер если есть
        stopCallTimer()
        
        callStartTime = Date()
        lastUpdateTime = Date()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.callDuration = 0
            
            // Создаем таймер на главном потоке
            self.callTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                
                // Проверяем, что звонок все еще активен
                if self.callState == .connected {
                    // Увеличиваем длительность на 1 секунду
                    DispatchQueue.main.async {
                        self.callDuration += 1
                        // Для отладки - каждые 10 секунд выводим время
                        if Int(self.callDuration) % 10 == 0 {
                            print("⏱️ Call duration: \(Int(self.callDuration)) sec")
                        }
                    }
                } else {
                    // Если звонок не активен, останавливаем таймер
                    print("⏱️ Call not active, stopping timer")
                    timer.invalidate()
                    self.callTimer = nil
                }
            }
            
            // Добавляем таймер в common run loop modes чтобы он работал во время скролла
            RunLoop.current.add(self.callTimer!, forMode: .common)
        }
    }
    
    private func stopCallTimer() {
        print("⏱️ Stopping call timer, final duration: \(Int(callDuration)) sec")
        
        DispatchQueue.main.async { [weak self] in
            self?.callTimer?.invalidate()
            self?.callTimer = nil
            // НЕ сбрасываем callDuration здесь, чтобы сохранить финальное значение
        }
    }
    
    // MARK: - Фоновая задача
    
    private func startBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
        
        // Запускаем таймер для поддержания соединения в фоне
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            print("📱 Keeping connection alive in background")
            if WebSocketService.shared.isConnected {
                WebSocketService.shared.send(dictionary: ["type": "ping", "timestamp": Date().timeIntervalSince1970])
            }
        }
    }
    
    private func endBackgroundTask() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    
    // MARK: - Обработка событий приложения
    
    @objc private func handleAppDidEnterBackground() {
        print("📱 App entered background")
        
        if callState == .connected {
            startBackgroundTask()
        }
    }
    
    @objc private func handleAppWillEnterForeground() {
        print("📱 App will enter foreground")
        
        if callState == .connected {
            endBackgroundTask()
        }
    }
    
    // MARK: - Обработка аудио прерываний
    
    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        switch type {
        case .began:
            print("🔇 Audio interruption began")
            
        case .ended:
            print("🔊 Audio interruption ended")
            // Прерывание закончилось, пробуем восстановить аудио
            if callState == .connected {
                do {
                    try audioSession.setActive(true)
                    print("🔊 Audio session reactivated after interruption")
                } catch {
                    print("❌ Failed to reactivate audio session: \(error)")
                }
            }
        @unknown default:
            break
        }
    }
    
    // MARK: - Показ UI
    
    private func showIncomingCallUI(callerInfo: CallerInfo) {
        // Отправляем уведомление для показа кастомного интерфейса
        NotificationCenter.default.post(
            name: NSNotification.Name("ShowIncomingCallUI"),
            object: nil,
            userInfo: [
                "callerName": callerInfo.callerName,
                "hasVideo": callerInfo.hasVideo,
                "callId": callerInfo.callId,
                "sessionUUID": callerInfo.sessionUUID
            ]
        )
    }
    
    // MARK: - Форматирование
    
    func formatDuration() -> String {
        let duration = Int(callDuration)
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60
        let seconds = duration % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
    
    // MARK: - Сброс
    
    func reset() {
        print("🔄 Resetting CustomCallManager")
        
        stopCallTimer()
        endBackgroundTask()
        
        if callState != .idle {
            webRTCManager.endCall()
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.callState = .idle
            self?.isIncomingCall = false
            self?.callerInfo = nil
            self?.callDuration = 0
        }
        
        deactivateAudioSession()
    }
    
    deinit {
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        volumeObserver?.invalidate()
    }
}
