import Foundation
import AVFoundation
import AudioToolbox
import UIKit

// MARK: - Call Sound Manager
class CallSoundManager: NSObject {
    static let shared = CallSoundManager()
    
    private var audioPlayer: AVAudioPlayer?
    private var vibrationTimer: Timer?
    private var ringtonePlayer: AVAudioPlayer?
    private var systemSoundTimer: Timer?
    
    private override init() {
        super.init()
        setupAudioSession()
        prepareRingtone()
        setupNotifications()
    }
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, // Меняем на .playback для рингтона
                                   mode: .default,
                                   options: [.mixWithOthers, .duckOthers]) // Добавляем duckOthers чтобы приглушить другую музыку
            try session.setActive(true)
            print("✅ CallSoundManager: Audio session configured for ringtone")
        } catch {
            print("❌ CallSoundManager: Error setting up audio session: \(error)")
        }
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCallStateChanged),
            name: NSNotification.Name("CallStateChangedNotification"),
            object: nil
        )
        
        // Добавляем наблюдатель для остановки рингтона при сворачивании приложения
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }
    
    @objc private func handleCallStateChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let stateValue = userInfo["state"] as? Int else { return }
        
        switch stateValue {
        case 1: // incoming
            startRinging()
        case 2: // connecting
            stopRinging()
        case 3: // connected
            stopRinging()
            playCallConnected()
            
            // Возвращаем аудио сессию в режим разговора
            setupCallAudioSession()
        case 0: // idle
            stopRinging()
            playCallEnded()
            
            // Возвращаем сессию в обычный режим
            setupAudioSession()
        default:
            break
        }
    }
    
    @objc private func handleAppDidEnterBackground() {
        // Останавливаем рингтон при сворачивании приложения
        stopRinging()
    }
    
    // Настройка аудио сессии для разговора
    private func setupCallAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord,
                                   mode: .voiceChat,
                                   options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try session.setActive(true)
            print("✅ CallSoundManager: Switched to call audio session")
        } catch {
            print("❌ CallSoundManager: Error switching to call session: \(error)")
        }
    }
    
    private func prepareRingtone() {
        // Сначала пробуем найти ringtone.mp3 в основных бандлах
        if let url = Bundle.main.url(forResource: "ringtone", withExtension: "mp3") {
            do {
                ringtonePlayer = try AVAudioPlayer(contentsOf: url)
                ringtonePlayer?.numberOfLoops = -1 // Бесконечное повторение
                ringtonePlayer?.volume = 1.0
                ringtonePlayer?.prepareToPlay()
                print("✅ CallSoundManager: Ringtone loaded: ringtone.mp3")
                return
            } catch {
                print("❌ CallSoundManager: Could not load ringtone.mp3: \(error)")
            }
        }
        
        // Если не нашли, пробуем другие варианты
        let ringtoneNames = ["ringtone", "call", "incoming", "phone_ring"]
        let extensions = ["mp3", "wav", "caf", "m4r"]
        
        for name in ringtoneNames {
            for ext in extensions {
                if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                    do {
                        ringtonePlayer = try AVAudioPlayer(contentsOf: url)
                        ringtonePlayer?.numberOfLoops = -1
                        ringtonePlayer?.volume = 1.0
                        ringtonePlayer?.prepareToPlay()
                        print("✅ CallSoundManager: Ringtone loaded: \(name).\(ext)")
                        return
                    } catch {
                        print("⚠️ CallSoundManager: Could not load \(name).\(ext): \(error)")
                    }
                }
            }
        }
        print("⚠️ CallSoundManager: No custom ringtone found, will use system sounds")
    }
    
    func startRinging() {
        print("🔔 CallSoundManager: Starting ringtone")
        
        // Переключаем аудио сессию для рингтона
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback,
                                   mode: .default,
                                   options: [.duckOthers])
            try session.setActive(true)
        } catch {
            print("❌ Failed to set audio session for ringtone: \(error)")
        }
        
        // Проигрываем рингтон если он загружен
        if let player = ringtonePlayer {
            player.currentTime = 0
            player.play()
            print("🔊 Playing custom ringtone")
        } else {
            // Если нет кастомного рингтона, используем системный звук
            playSystemRingtone()
        }
        
        startVibration()
    }
    
    private func playSystemRingtone() {
        // Проигрываем системный рингтон (звук входящего звонка)
        systemSoundTimer?.invalidate()
        systemSoundTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            AudioServicesPlaySystemSound(1003) // 1003 - стандартный рингтон iPhone
            print("📱 Playing system ringtone")
        }
        systemSoundTimer?.fire()
    }
    
    func stopRinging() {
        print("🔕 CallSoundManager: Stopping ringtone")
        
        // Останавливаем все звуки и вибрации
        ringtonePlayer?.stop()
        audioPlayer?.stop()
        vibrationTimer?.invalidate()
        systemSoundTimer?.invalidate()
    }
    
    func playCallConnected() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            AudioServicesPlaySystemSound(1057) // Звук соединения
            print("🔊 Playing connected sound (1057)")
        }
    }
    
    func playCallEnded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            AudioServicesPlaySystemSound(1075) // Звук завершения
            print("🔊 Playing ended sound (1075)")
        }
    }
    
    func playBusyTone() {
        AudioServicesPlaySystemSound(1070) // Звук "занято"
        print("🔊 Playing busy tone (1070)")
        
        // Короткая вибрация
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }
    
    private func startVibration() {
        // Немедленная вибрация при старте
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        
        // Запускаем таймер для периодической вибрации
        vibrationTimer?.invalidate()
        vibrationTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            print("📳 Vibration")
        }
    }
    
    // Для обратной совместимости
    func playCallAccepted() {
        playCallConnected()
    }
    
    func playCallRejected() {
        playBusyTone()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
