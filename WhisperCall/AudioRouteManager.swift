import Foundation
import AVFoundation
import Combine
import MediaPlayer

// MARK: - Audio Route Manager
final class AudioRouteManager: NSObject, ObservableObject {
    static let shared = AudioRouteManager()
    
    @Published var currentRoute: AudioRoute = .builtInSpeaker
    @Published var availableRoutes: [AudioRoute] = []
    @Published var isBluetoothAvailable: Bool = false
    @Published var isSpeakerAvailable: Bool = true
    @Published var isHeadphonesAvailable: Bool = false
    @Published var currentOutputVolume: Float = 0.5
    
    private var audioSession = AVAudioSession.sharedInstance()
    private var cancellables = Set<AnyCancellable>()
    private var routeChangeObserver: NSObjectProtocol?
    private var volumeObserver: NSKeyValueObservation?
    
    enum AudioRoute: String, CaseIterable {
        case builtInSpeaker = "Встроенный динамик"
        case builtInReceiver = "Разговорный динамик"
        case headphones = "Наушники"
        case bluetooth = "Bluetooth"
        case airPods = "AirPods"
        case carAudio = "Автомобиль"
        
        var icon: String {
            switch self {
            case .builtInSpeaker: return "speaker.wave.2.fill"
            case .builtInReceiver: return "speaker.fill"
            case .headphones: return "headphones"
            case .bluetooth: return "beats.fit.pro"
            case .airPods: return "airpodspro"
            case .carAudio: return "car"
            }
        }
        
        var priority: Int {
            switch self {
            case .airPods: return 100
            case .bluetooth: return 90
            case .headphones: return 80
            case .builtInSpeaker: return 70
            case .builtInReceiver: return 60
            case .carAudio: return 85
            }
        }
    }
    
    private override init() {
        super.init()
        setupAudioSession()
        setupRouteObservers()
        updateAvailableRoutes()
        setupVolumeObserver()
    }
    
    // MARK: - Setup
    
    private func setupAudioSession() {
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [
                    .allowBluetooth,
                    .allowBluetoothA2DP,
                    .allowAirPlay,
                    .defaultToSpeaker
                ]
            )
            try audioSession.setActive(true)
            print("✅ Audio session configured for calls")
        } catch {
            print("❌ Failed to configure audio session: \(error)")
        }
    }
    
    private func setupRouteObservers() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }
    }
    
    private func setupVolumeObserver() {
        // Используем современный KVO через NSKeyValueObservation
        volumeObserver = audioSession.observe(\.outputVolume, options: [.new]) { [weak self] session, change in
            DispatchQueue.main.async {
                self?.currentOutputVolume = session.outputVolume
            }
        }
        
        // Получаем начальное значение громкости
        currentOutputVolume = audioSession.outputVolume
    }
    
    // MARK: - Route Management
    
    private func handleRouteChange(_ notification: Notification) {
        updateAvailableRoutes()
        updateCurrentRoute()
        
        // Уведомляем об изменении маршрута
        NotificationCenter.default.post(
            name: .audioRouteDidChange,
            object: currentRoute
        )
    }
    
    func updateAvailableRoutes() {
        var routes: [AudioRoute] = []
        
        // Проверяем доступные выходы
        let availableOutputs = audioSession.currentRoute.outputs
        
        // Bluetooth
        if isBluetoothDeviceConnected() {
            routes.append(.bluetooth)
            isBluetoothAvailable = true
        } else {
            isBluetoothAvailable = false
        }
        
        // Проверяем наличие проводных наушников
        if hasWiredHeadphones() {
            routes.append(.headphones)
            isHeadphonesAvailable = true
        } else {
            isHeadphonesAvailable = false
        }
        
        // AirPods (специфичная проверка)
        if hasAirPods() {
            routes.append(.airPods)
        }
        
        // Динамик всегда доступен
        routes.append(.builtInSpeaker)
        routes.append(.builtInReceiver)
        
        // Сортируем по приоритету
        availableRoutes = routes.sorted { $0.priority > $1.priority }
    }
    
    private func updateCurrentRoute() {
        let outputs = audioSession.currentRoute.outputs
        
        if let port = outputs.first {
            switch port.portType {
            case .builtInSpeaker:
                currentRoute = .builtInSpeaker
            case .builtInReceiver:
                currentRoute = .builtInReceiver
            case .headphones, .headsetMic:
                currentRoute = .headphones
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
                currentRoute = .bluetooth
            case .carAudio:
                currentRoute = .carAudio
            default:
                if port.portName.contains("AirPods") {
                    currentRoute = .airPods
                } else {
                    currentRoute = .builtInSpeaker
                }
            }
        }
    }
    
    // MARK: - Device Checks
    
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
    
    // MARK: - Route Switching
    
    func switchToSpeaker() {
        do {
            try audioSession.overrideOutputAudioPort(.speaker)
            print("🔊 Switched to speaker")
            
            // Обновляем текущий маршрут
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.updateCurrentRoute()
            }
        } catch {
            print("❌ Failed to switch to speaker: \(error)")
        }
    }
    
    func switchToReceiver() {
        do {
            try audioSession.overrideOutputAudioPort(.none)
            print("📞 Switched to receiver")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.updateCurrentRoute()
            }
        } catch {
            print("❌ Failed to switch to receiver: \(error)")
        }
    }
    
    func switchToBluetooth() {
        do {
            // Убираем override на динамик, система автоматически выберет Bluetooth
            try audioSession.overrideOutputAudioPort(.none)
            print("📱 Switched to bluetooth")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.updateCurrentRoute()
            }
        } catch {
            print("❌ Failed to switch to bluetooth: \(error)")
        }
    }
    
    // НОВЫЙ МЕТОД: toggleBluetooth
    func toggleBluetooth() {
        if isBluetoothAvailable {
            if currentRoute == .bluetooth || currentRoute == .airPods {
                // Если уже на Bluetooth, переключаем на динамик
                switchToSpeaker()
            } else {
                // Переключаем на Bluetooth
                switchToBluetooth()
            }
        } else {
            // Если Bluetooth недоступен, показываем уведомление
            print("⚠️ Bluetooth not available")
            NotificationCenter.default.post(
                name: NSNotification.Name("ShowToastNotification"),
                object: "Bluetooth устройство не найдено"
            )
        }
    }
    
    func forceRouteTo(_ route: AudioRoute) {
        switch route {
        case .builtInSpeaker:
            switchToSpeaker()
        case .builtInReceiver:
            switchToReceiver()
        case .bluetooth, .airPods:
            switchToBluetooth()
        default:
            break
        }
    }
    
    // MARK: - Volume Control
    
    func setVolume(_ volume: Float) {
        let volumeView = MPVolumeView()
        if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                slider.value = volume
            }
        }
    }
    
    func increaseVolume() {
        setVolume(min(currentOutputVolume + 0.1, 1.0))
    }
    
    func decreaseVolume() {
        setVolume(max(currentOutputVolume - 0.1, 0.0))
    }
    
    // MARK: - Cleanup
    
    deinit {
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        volumeObserver?.invalidate()
    }
}

// MARK: - Notification Extension
extension Notification.Name {
    static let audioRouteDidChange = Notification.Name("audioRouteDidChange")
    static let showToastNotification = Notification.Name("ShowToastNotification")
}
