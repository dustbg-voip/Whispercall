import Foundation
import WebRTC
import Combine
import AVFoundation

final class WebRTCManager: NSObject, ObservableObject {
    static let shared = WebRTCManager()
    
    private let factory = RTCPeerConnectionFactory()
    private var peerConnection: RTCPeerConnection?
    
    // Аудио треки
    private(set) var localAudioTrack: RTCAudioTrack?
    private(set) var remoteAudioTrack: RTCAudioTrack?
    
    // Видео треки
    private(set) var localVideoTrack: RTCVideoTrack?
    private(set) var remoteVideoTrack: RTCVideoTrack?
    
    private var videoCapturer: RTCVideoCapturer?
    private var videoSource: RTCVideoSource?
    
    @Published var callState: CallState = .idle
    @Published var callDuration: TimeInterval = 0
    @Published var isVideoEnabled: Bool = false
    @Published var isRemoteVideoEnabled: Bool = false
    @Published var cameraPosition: CameraPosition = .front
    
    private var callTimer: Timer?
    private var callStartTime: Date?
    private var incomingCallId: String?
    private var currentCallId: String?
    private var sessionUUID: String?
    private var currentCallUUID: UUID?
    
    // Флаг для отслеживания типа звонка
    private var currentCallHasVideo: Bool = false
    
    enum CallState: Int {
        case idle = 0
        case incoming = 1
        case connecting = 2
        case connected = 3
    }
    
    enum CameraPosition {
        case front, back
    }
    
    var isInCall: Bool {
        return callState != .idle
    }
    
    private override init() {
        super.init()
        configureAudioSession()
        setupAudioTrack()
        checkCameraPermission()
        print("🔹 WebRTCManager initialized")
    }
    
    // MARK: - Permission Checks
    
    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            print("✅ Camera permission granted")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                print("📹 Camera permission: \(granted)")
            }
        case .denied, .restricted:
            print("❌ Camera permission denied")
        @unknown default:
            break
        }
    }
    
    // MARK: - Audio Track Setup
    
    private func setupAudioTrack() {
        print("🔊 Setting up audio track...")
        
        // Создаем аудио констрейнты для лучшего качества
        let audioSource = factory.audioSource(with: nil)
        
        localAudioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        localAudioTrack?.isEnabled = true
        
        print("🔊 Local audio track created and enabled")
    }
    
    // MARK: - Video Setup
    
    private func setupVideo() {
        #if !targetEnvironment(simulator)
        print("🎥 Setting up video...")
        
        // Создаем видео источник
        videoSource = factory.videoSource()
        
        // Настраиваем захват с камеры
        setupCameraCapture()
        
        // Создаем видео трек
        if let videoSource = videoSource {
            localVideoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
            localVideoTrack?.isEnabled = true
            print("🎥 Local video track created and enabled")
        }
        #endif
    }
    
    private func setupCameraCapture() {
        #if !targetEnvironment(simulator)
        guard let videoSource = videoSource else { return }
        
        // Выбираем фронтальную камеру по умолчанию
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTrueDepthCamera],
            mediaType: .video,
            position: .front
        )
        
        guard let cameraDevice = discoverySession.devices.first else {
            print("❌ No camera available")
            return
        }
        
        // Создаем видеозахватчик
        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        videoCapturer = capturer
        
        // Запускаем захват
        let formats = RTCCameraVideoCapturer.supportedFormats(for: cameraDevice)
        guard let format = formats.last else { return }
        
        let fps = format.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30
        
        capturer.startCapture(with: cameraDevice,
                             format: format,
                             fps: Int(fps))
        
        print("🎥 Camera capture started: \(cameraDevice.localizedName)")
        #endif
    }
    
    private func stopVideoCapture() {
        #if !targetEnvironment(simulator)
        if let capturer = videoCapturer as? RTCCameraVideoCapturer {
            capturer.stopCapture()
            print("🎥 Video capture stopped")
        }
        videoCapturer = nil
        videoSource = nil
        localVideoTrack = nil
        #endif
    }
    
    func switchCamera() {
        #if !targetEnvironment(simulator)
        guard let capturer = videoCapturer as? RTCCameraVideoCapturer else { return }
        
        // Определяем новую позицию камеры
        let newPosition: AVCaptureDevice.Position = cameraPosition == .front ? .back : .front
        cameraPosition = newPosition == .front ? .front : .back
        
        // Находим новое устройство
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: newPosition
        )
        
        if let newDevice = discoverySession.devices.first,
           let format = RTCCameraVideoCapturer.supportedFormats(for: newDevice).last {
            
            let fps = format.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30
            capturer.startCapture(with: newDevice, format: format, fps: Int(fps))
            
            print("🔄 Camera switched to: \(newPosition == .front ? "front" : "back")")
        }
        #endif
    }
    
    func toggleVideo() {
        isVideoEnabled.toggle()
        
        if isVideoEnabled {
            // Включаем видео
            if localVideoTrack == nil {
                setupVideo()
            }
            
            // Добавляем видео трек в peer connection, если его еще нет
            if let videoTrack = localVideoTrack,
               let pc = peerConnection {
                // Проверяем, есть ли уже видео трек
                let hasVideoSender = pc.senders.contains { $0.track?.kind == "video" }
                if !hasVideoSender {
                    let sender = pc.add(videoTrack, streamIds: ["stream0"])
                    print("🎥 Video track added to peer connection")
                }
            }
        } else {
            // Выключаем видео - удаляем трек из peer connection
            if let pc = peerConnection {
                let senders = pc.senders
                for sender in senders where sender.track?.kind == "video" {
                    pc.removeTrack(sender)
                    print("🎥 Video track removed from peer connection")
                }
            }
        }
    }
    
    // MARK: - Audio Management
    
    func toggleSpeaker() {
        let session = AVAudioSession.sharedInstance()
        do {
            if session.currentRoute.outputs.first?.portType == .builtInSpeaker {
                try session.overrideOutputAudioPort(.none)
                print("🔊 Switched to receiver")
            } else {
                try session.overrideOutputAudioPort(.speaker)
                print("🔊 Switched to speaker")
            }
        } catch {
            print("❌ Failed to toggle speaker: \(error)")
        }
    }
    
    func toggleBluetooth() {
        // Просто сбрасываем настройки, система сама выберет Bluetooth если доступен
        let session = AVAudioSession.sharedInstance()
        do {
            try session.overrideOutputAudioPort(.none)
            print("📱 Switched to bluetooth/none")
        } catch {
            print("❌ Failed to switch audio route: \(error)")
        }
    }
    
    // MARK: - TIME
    
    private func localTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
    
    // MARK: - AUDIO SESSION
    
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                   mode: .voiceChat,
                                   options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers])
            try session.setActive(true)
            RTCAudioSession.sharedInstance().isAudioEnabled = true
            print("🔊 AVAudioSession configured")
        } catch {
            print("❌ AVAudioSession setup failed: \(error)")
        }
    }
    
    func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true)
            RTCAudioSession.sharedInstance().isAudioEnabled = true
            print("🔊 Audio session activated")
        } catch {
            print("❌ Failed to activate audio session: \(error)")
        }
    }
    
    func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            RTCAudioSession.sharedInstance().isAudioEnabled = false
            print("🔇 Audio session deactivated")
        } catch {
            print("❌ Failed to deactivate audio session: \(error)")
        }
    }
    
    // Полный сброс аудио сессии
    private func resetAudioSession() {
        deactivateAudioSession()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.configureAudioSession()
        }
    }
    
    // MARK: - CALL MANAGEMENT
    
    func startCall(sessionUUID: String, to peerName: String, withVideo: Bool = false) async {
        guard callState == .idle else { return }
        
        resetAudioSession()
        
        self.sessionUUID = sessionUUID
        self.currentCallId = "\(Date().timeIntervalSince1970)"
        self.currentCallUUID = UUID()
        self.isVideoEnabled = withVideo
        self.currentCallHasVideo = withVideo
        
        print("📞 Starting \(withVideo ? "video" : "audio") call to \(peerName), session: \(sessionUUID)")
        
        activateAudioSession()
        
        DispatchQueue.main.async { self.callState = .connecting }
        
        // Создаем peer connection с видео
        setupPeerConnection(withVideo: withVideo)
        
        // Если это видеозвонок, убеждаемся что видео трек создан и добавлен
        if withVideo && localVideoTrack == nil {
            setupVideo()
            if let videoTrack = localVideoTrack {
                peerConnection?.add(videoTrack, streamIds: ["stream0"])
                print("🎥 Video track added to peer connection in startCall")
            }
        }
        
        await createOffer(to: peerName, withVideo: withVideo)
        
        NotificationCenter.default.post(
            name: NSNotification.Name("CallStateChangedNotification"),
            object: nil,
            userInfo: ["state": callState.rawValue]
        )
    }
    
    func receiveCall(sessionUUID: String, callId: String, sdp: String, hasVideo: Bool = false) {
        guard callState == .idle else {
            print("❌ Incoming call ignored, another call is active")
            return
        }
        
        resetAudioSession()
        
        self.sessionUUID = sessionUUID
        self.incomingCallId = callId
        self.currentCallUUID = UUID()
        self.isRemoteVideoEnabled = hasVideo
        self.currentCallHasVideo = hasVideo
        
        print("📥 Incoming \(hasVideo ? "video" : "audio") call received | callId: \(callId), session: \(sessionUUID)")
        
        activateAudioSession()
        
        DispatchQueue.main.async { self.callState = .incoming }
        
        // Создаем peer connection с учетом видео
        setupPeerConnection(withVideo: hasVideo)
        
        // Если это видеозвонок, создаем и добавляем видео трек
        if hasVideo {
            setupVideo()
            if let videoTrack = localVideoTrack {
                // Проверяем, не добавлен ли уже видео трек
                let hasVideoSender = peerConnection?.senders.contains { $0.track?.kind == "video" } ?? false
                if !hasVideoSender {
                    peerConnection?.add(videoTrack, streamIds: ["stream0"])
                    isVideoEnabled = true
                    print("🎥 Video track added to peer connection in receiveCall")
                }
            }
        }
        
        NotificationCenter.default.post(
            name: NSNotification.Name("IncomingCallNotification"),
            object: nil,
            userInfo: [
                "callId": callId,
                "sessionUUID": sessionUUID,
                "from": "Клиент",
                "hasVideo": hasVideo,
                "timestamp": Date().timeIntervalSince1970
            ]
        )
        
        let remoteSDP = RTCSessionDescription(type: .offer, sdp: sdp)
        peerConnection?.setRemoteDescription(remoteSDP) { [weak self] error in
            if let error = error {
                print("❌ setRemoteDescription failed: \(error)")
            } else {
                print("✅ Remote SDP set for incoming call")
            }
        }
    }
    
    func answerCall(to peerName: String) async {
        guard let pc = peerConnection, let callId = incomingCallId else {
            print("❌ Cannot answer call: peerConnection or callId is nil")
            return
        }
        
        print("📞 Answering call, hasVideo: \(currentCallHasVideo)")
        
        // Убеждаемся что аудио трек включен
        localAudioTrack?.isEnabled = true
        
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": currentCallHasVideo ? "true" : "false"
            ],
            optionalConstraints: nil
        )
        
        do {
            let answer = try await pc.answer(for: constraints)
            try await pc.setLocalDescription(answer)
            
            let payload: [String: Any] = [
                "type": "call_answer",
                "sdp": answer.sdp,
                "from": "iOSAdmin",
                "to": peerName,
                "callId": callId,
                "session_uuid": sessionUUID ?? "",
                "hasVideo": currentCallHasVideo,
                "timestamp": localTimestamp()
            ]
            WebSocketService.shared.send(dictionary: payload)
            
            currentCallId = callId
            incomingCallId = nil
            
            DispatchQueue.main.async {
                self.callState = .connected
                self.startCallTimer()
                print("✅ Call answered, connected to \(peerName)")
                
                NotificationCenter.default.post(
                    name: NSNotification.Name("CallStateChangedNotification"),
                    object: nil,
                    userInfo: ["state": self.callState.rawValue]
                )
                
                if self.currentCallHasVideo {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("VideoCallConnectedNotification"),
                        object: nil,
                        userInfo: nil
                    )
                }
            }
            
            NotificationCenter.default.post(
                name: NSNotification.Name("CallAcceptedNotification"),
                object: nil,
                userInfo: ["peerName": peerName, "hasVideo": currentCallHasVideo]
            )
        } catch {
            print("❌ Answer failed: \(error)")
        }
    }
    
    func setRemoteAnswer(sdp: String) async {
        guard let pc = peerConnection else { return }
        let remoteSDP = RTCSessionDescription(type: .answer, sdp: sdp)
        do {
            try await pc.setRemoteDescription(remoteSDP)
            
            // Убеждаемся что аудио трек включен после установки соединения
            DispatchQueue.main.async {
                self.remoteAudioTrack?.isEnabled = true
                self.localAudioTrack?.isEnabled = true
                
                self.callState = .connected
                self.startCallTimer()
                print("✅ Remote answer applied, call connected")
                
                NotificationCenter.default.post(
                    name: NSNotification.Name("CallStateChangedNotification"),
                    object: nil,
                    userInfo: ["state": self.callState.rawValue]
                )
            }
        } catch {
            print("❌ Set remote answer failed: \(error)")
        }
    }
    
    func addRemoteIceCandidate(_ candidate: RTCIceCandidate) {
        peerConnection?.add(candidate)
        print("🔹 Remote ICE candidate added")
    }
    
    func endCall(to peerName: String? = nil) {
        let activeSession = sessionUUID
        let finalDuration = Int(callDuration)
        let hadVideo = currentCallHasVideo
        
        stopCallTimer()
        DispatchQueue.main.async { self.callState = .idle }
        
        if let sessionUUID = activeSession, finalDuration > 0, callStartTime != nil {
            WebSocketService.shared.sendCallLogMessage(
                sessionUUID: sessionUUID,
                duration: finalDuration
            )
            print("📞 Call ended, duration: \(finalDuration)s")
        }
        
        NotificationCenter.default.post(
            name: NSNotification.Name("CallStateChangedNotification"),
            object: nil,
            userInfo: ["state": callState.rawValue]
        )
        
        cleanup()
        
        if let peerName = peerName, let sessionUUID = activeSession {
            let payload: [String: Any] = [
                "type": "call_end",
                "from": "iOSAdmin",
                "to": peerName,
                "session_uuid": sessionUUID,
                "timestamp": localTimestamp()
            ]
            WebSocketService.shared.send(dictionary: payload)
        }
        
        NotificationCenter.default.post(
            name: NSNotification.Name("CallEndedNotification"),
            object: nil,
            userInfo: ["hadVideo": hadVideo]
        )
        
        print("📴 Call ended")
    }
    
    private func cleanup() {
        peerConnection?.close()
        peerConnection = nil
        
        stopVideoCapture()
        
        remoteAudioTrack = nil
        remoteVideoTrack = nil
        
        incomingCallId = nil
        currentCallId = nil
        sessionUUID = nil
        callStartTime = nil
        currentCallUUID = nil
        isVideoEnabled = false
        isRemoteVideoEnabled = false
        currentCallHasVideo = false
        
        DispatchQueue.main.async { [weak self] in
            self?.resetAudioSession()
        }
    }
    
    // MARK: - PEER CONNECTION
    
    private func setupPeerConnection(withVideo: Bool = false) {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        
        config.iceServers = [
            RTCIceServer(urlStrings: ["turn:77.41.177.55:3478?transport=udp"], username: "DUSTBG", credential: "DUSTISROOT"),
            RTCIceServer(urlStrings: ["turn:77.41.177.55:3478?transport=tcp"], username: "DUSTBG", credential: "DUSTISROOT"),
            RTCIceServer(urlStrings: ["turns:77.41.177.55:443?transport=tcp"], username: "DUSTBG", credential: "DUSTISROOT"),
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
        ]
        
        config.iceTransportPolicy = .all
        config.iceCandidatePoolSize = 10
        
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)
        
        // ВАЖНО: Добавляем аудио трек с правильными настройками
        if let audioTrack = localAudioTrack {
            audioTrack.isEnabled = true
            
            // Проверяем, есть ли уже аудио трек
            let hasAudioSender = peerConnection?.senders.contains { $0.track?.kind == "audio" } ?? false
            if !hasAudioSender {
                let audioSender = peerConnection?.add(audioTrack, streamIds: ["stream0"])
                print("🔊 Audio track added to peer connection, sender: \(audioSender != nil)")
            } else {
                print("🔊 Audio track already exists in peer connection")
            }
        } else {
            print("❌ Local audio track is nil, recreating...")
            setupAudioTrack()
            if let audioTrack = localAudioTrack {
                peerConnection?.add(audioTrack, streamIds: ["stream0"])
                print("🔊 Audio track recreated and added")
            }
        }
        
        // Добавляем видео трек сразу, если это видеозвонок
        if withVideo {
            print("🎥 Setting up video for peer connection...")
            
            // Создаем видео трек
            if localVideoTrack == nil {
                setupVideo()
            }
            
            // Добавляем видео трек в peer connection
            if let videoTrack = localVideoTrack {
                videoTrack.isEnabled = true
                let hasVideoSender = peerConnection?.senders.contains { $0.track?.kind == "video" } ?? false
                if !hasVideoSender {
                    let videoSender = peerConnection?.add(videoTrack, streamIds: ["stream0"])
                    isVideoEnabled = true
                    print("🎥 Video track added to peer connection, sender: \(videoSender != nil)")
                } else {
                    print("🎥 Video track already exists in peer connection")
                }
            } else {
                print("❌ Failed to create video track")
            }
        }
        
        // Проверяем, что треки добавлены
        if let pc = peerConnection {
            let senders = pc.senders
            print("📤 Peer connection senders after setup: \(senders.map { $0.track?.kind ?? "unknown" })")
            
            // Дополнительно проверяем аудио
            if senders.first(where: { $0.track?.kind == "audio" }) == nil {
                print("⚠️ No audio sender found, trying to add again...")
                if let audioTrack = localAudioTrack {
                    peerConnection?.add(audioTrack, streamIds: ["stream0"])
                }
            }
        }
        
        print("🔹 PeerConnection setup complete" + (withVideo ? " with video" : ""))
    }
    
    private func createOffer(to peerName: String, withVideo: Bool) async {
        guard let pc = peerConnection, let sessionUUID = sessionUUID, let callId = currentCallId else {
            print("❌ Cannot create offer: missing parameters")
            return
        }
        
        // Проверяем отправляемые треки перед созданием offer
        let senders = pc.senders
        print("📤 Creating offer with senders: \(senders.map { $0.track?.kind ?? "unknown" })")
        
        // Убеждаемся что аудио трек включен
        localAudioTrack?.isEnabled = true
        
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": withVideo ? "true" : "false"
            ],
            optionalConstraints: nil
        )
        
        do {
            let offer = try await pc.offer(for: constraints)
            try await pc.setLocalDescription(offer)
            
            let payload: [String: Any] = [
                "type": "call_offer",
                "from": "iOSAdmin",
                "to": peerName,
                "sdp": offer.sdp,
                "callId": callId,
                "session_uuid": sessionUUID,
                "hasVideo": withVideo,
                "timestamp": localTimestamp()
            ]
            WebSocketService.shared.send(dictionary: payload)
            print("📤 Call offer sent to \(peerName), hasVideo: \(withVideo)")
        } catch {
            print("❌ Offer failed: \(error)")
        }
    }
    
    // MARK: - CALL TIMER
    
    private func startCallTimer() {
        callStartTime = Date()
        DispatchQueue.main.async {
            self.callDuration = 0
            self.callTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.callDuration += 1
            }
        }
    }
    
    private func stopCallTimer() {
        callTimer?.invalidate()
        callTimer = nil
        DispatchQueue.main.async { self.callDuration = 0 }
    }
    
    // MARK: - ВСПОМОГАТЕЛЬНЫЕ МЕТОДЫ
    
    func declineCall() {
        if let callId = incomingCallId {
            let payload: [String: Any] = [
                "type": "call_reject",
                "callId": callId,
                "from": "iOSAdmin",
                "session_uuid": sessionUUID ?? "",
                "timestamp": localTimestamp()
            ]
            WebSocketService.shared.send(dictionary: payload)
        }
        
        NotificationCenter.default.post(
            name: NSNotification.Name("CallDeclinedNotification"),
            object: nil
        )
        
        stopCallTimer()
        DispatchQueue.main.async { self.callState = .idle }
        
        NotificationCenter.default.post(
            name: NSNotification.Name("CallStateChangedNotification"),
            object: nil,
            userInfo: ["state": callState.rawValue]
        )
        
        cleanup()
        
        print("📴 Call declined")
    }
}

// MARK: - PEER CONNECTION DELEGATE

extension WebRTCManager: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        print("📥 didAdd rtpReceiver, streams count: \(streams.count)")
        
        for stream in streams {
            print("   Stream id: \(stream.streamId)")
            print("   Video tracks: \(stream.videoTracks.count)")
            print("   Audio tracks: \(stream.audioTracks.count)")
            
            // Получаем видео треки
            if let videoTrack = stream.videoTracks.first {
                DispatchQueue.main.async {
                    self.remoteVideoTrack = videoTrack
                    self.remoteVideoTrack?.isEnabled = true
                    self.isRemoteVideoEnabled = true
                    print("🎥 Remote video track received and set from rtpReceiver")
                    
                    NotificationCenter.default.post(
                        name: NSNotification.Name("RemoteVideoTrackReceived"),
                        object: nil,
                        userInfo: ["track": videoTrack]
                    )
                }
            }
            
            // ВАЖНО: Получаем и включаем аудио треки
            if let audioTrack = stream.audioTracks.first {
                DispatchQueue.main.async {
                    self.remoteAudioTrack = audioTrack
                    self.remoteAudioTrack?.isEnabled = true
                    print("🔊 Remote audio track received and ENABLED")
                    
                    // Дополнительно проверяем громкость
                    if let audioTrack = self.remoteAudioTrack {
                        print("🔊 Remote audio track - isEnabled: \(audioTrack.isEnabled)")
                    }
                }
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("📥 didAdd stream: \(stream.streamId)")
        print("   - Video tracks: \(stream.videoTracks.count)")
        print("   - Audio tracks: \(stream.audioTracks.count)")
        
        // Проверяем видео треки
        if let videoTrack = stream.videoTracks.first {
            DispatchQueue.main.async {
                self.remoteVideoTrack = videoTrack
                self.remoteVideoTrack?.isEnabled = true
                self.isRemoteVideoEnabled = true
                print("🎥 Remote video stream received and set")
                
                NotificationCenter.default.post(
                    name: NSNotification.Name("RemoteVideoTrackReceived"),
                    object: nil,
                    userInfo: ["track": videoTrack]
                )
            }
        }
        
        // ВАЖНО: Проверяем и включаем аудио треки
        if let audioTrack = stream.audioTracks.first {
            DispatchQueue.main.async {
                self.remoteAudioTrack = audioTrack
                self.remoteAudioTrack?.isEnabled = true
                print("🔊 Remote audio stream received and ENABLED")
                
                // Проверяем громкость
                print("🔊 Remote audio track - isEnabled: \(audioTrack.isEnabled)")
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        print("📤 Stream removed: \(stream.streamId)")
        if stream.videoTracks.first != nil {
            DispatchQueue.main.async {
                self.isRemoteVideoEnabled = false
                self.remoteVideoTrack = nil
            }
        }
        if stream.audioTracks.first != nil {
            DispatchQueue.main.async {
                self.remoteAudioTrack = nil
                print("🔊 Remote audio track removed")
            }
        }
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("🧊 ICE state changed: \(newState.rawValue)")
        
        switch newState {
        case .connected:
            print("✅ ICE connected - media should flow")
            
            // Проверяем отправляемые треки
            let senders = peerConnection.senders
            print("📤 Active senders: \(senders.map { $0.track?.kind ?? "unknown" })")
            
            // ВАЖНО: Убеждаемся что аудио треки включены
            DispatchQueue.main.async {
                self.localAudioTrack?.isEnabled = true
                self.remoteAudioTrack?.isEnabled = true
                print("🔊 Audio tracks enabled after ICE connected")
            }
            
        case .disconnected, .failed, .closed:
            print("⚠️ ICE connection lost, ending call")
            DispatchQueue.main.async {
                if self.callState != .idle {
                    self.endCall()
                }
            }
        default:
            break
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard let sessionUUID = sessionUUID, let callId = currentCallId else { return }
        let payload: [String: Any] = [
            "type": "ice_candidate",
            "candidate": [
                "candidate": candidate.sdp,
                "sdpMLineIndex": candidate.sdpMLineIndex,
                "sdpMid": candidate.sdpMid ?? ""
            ],
            "from": "iOSAdmin",
            "session_uuid": sessionUUID,
            "callId": callId,
            "timestamp": localTimestamp()
        ]
        WebSocketService.shared.send(dictionary: payload)
        print("📡 Local ICE candidate sent")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
