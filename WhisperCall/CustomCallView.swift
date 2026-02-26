import SwiftUI
import AVFoundation
import WebRTC

struct CustomCallView: View {
    @ObservedObject private var callManager = CustomCallManager.shared
    @ObservedObject private var rtcManager = WebRTCManager.shared
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.colorScheme) var colorScheme
    
    @State private var isMuted = false
    @State private var isSpeakerOn = true
    @State private var isVideoEnabled = false
    @State private var showAudioRoutes = false
    @State private var animateGradient = false
    
    var body: some View {
        ZStack {
            // Анимированный фон
            if callManager.callState == .incoming {
                incomingCallBackground
            } else if callManager.callState == .outgoing {
                outgoingCallBackground
            } else if callManager.callState == .connected {
                if rtcManager.isRemoteVideoEnabled {
                    CustomRemoteVideoView()
                        .edgesIgnoringSafeArea(.all)
                } else {
                    activeCallBackground
                }
            }
            
            // Контент в зависимости от состояния
            if callManager.callState == .incoming {
                incomingCallContent
            } else if callManager.callState == .outgoing {
                outgoingCallContent
            } else if callManager.callState == .connected {
                activeCallContent
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowIncomingCallUI"))) { _ in
            print("📱 ShowIncomingCallUI received")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CallShouldDismiss"))) { _ in
            print("📱 Received CallShouldDismiss notification")
            DispatchQueue.main.async {
                presentationMode.wrappedValue.dismiss()
            }
        }
        .onReceive(callManager.$callState) { newState in
            print("📱 Call state changed to: \(newState)")
            if newState == .idle || newState == .ended {
                DispatchQueue.main.async {
                    presentationMode.wrappedValue.dismiss()
                }
            }
        }
    }
    
    // MARK: - Backgrounds
    
    private var incomingCallBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.2, green: 0.3, blue: 0.8),
                    Color(red: 0.5, green: 0.2, blue: 0.7),
                    Color(red: 0.8, green: 0.2, blue: 0.5)
                ],
                startPoint: animateGradient ? .topLeading : .bottomLeading,
                endPoint: animateGradient ? .bottomTrailing : .topTrailing
            )
            .edgesIgnoringSafeArea(.all)
            .onAppear {
                withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: true)) {
                    animateGradient.toggle()
                }
            }
            
            // Эффект свечения
            Circle()
                .fill(Color.white.opacity(0.1))
                .scaleEffect(1.5)
                .blur(radius: 50)
                .offset(x: -100, y: -200)
            
            Circle()
                .fill(Color.purple.opacity(0.2))
                .scaleEffect(1.8)
                .blur(radius: 60)
                .offset(x: 150, y: 250)
        }
    }
    
    private var outgoingCallBackground: some View {
        ZStack {
            Color.black.opacity(0.9)
                .edgesIgnoringSafeArea(.all)
            
            // Пульсирующий круг
            Circle()
                .stroke(Color.blue.opacity(0.3), lineWidth: 2)
                .scaleEffect(animateGradient ? 1.2 : 0.8)
                .opacity(animateGradient ? 0 : 1)
                .animation(
                    Animation.easeInOut(duration: 2.0).repeatForever(autoreverses: false),
                    value: animateGradient
                )
                .onAppear {
                    animateGradient = true
                }
        }
    }
    
    private var activeCallBackground: some View {
        ZStack {
            // Градиент для аудиозвонка
            LinearGradient(
                colors: [
                    Color(red: 0.1, green: 0.1, blue: 0.2),
                    Color(red: 0.2, green: 0.1, blue: 0.3),
                    Color.black
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .edgesIgnoringSafeArea(.all)
            
            // Волны звука
            ForEach(0..<5) { index in
                Circle()
                    .stroke(Color.blue.opacity(0.2 - Double(index) * 0.03), lineWidth: 1)
                    .scaleEffect(animateGradient ? 1.5 + Double(index) * 0.3 : 0.8 + Double(index) * 0.2)
                    .opacity(animateGradient ? 0 : 0.5)
                    .animation(
                        Animation.easeInOut(duration: 3.0)
                            .repeatForever(autoreverses: false)
                            .delay(Double(index) * 0.5),
                        value: animateGradient
                    )
            }
            .onAppear {
                animateGradient = true
            }
        }
    }
    
    // MARK: - Incoming Call Content
    private var incomingCallContent: some View {
        VStack(spacing: 30) {
            Spacer()
            
            // Аватар звонящего
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 120, height: 120)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 2)
                    )
                
                Image(systemName: callManager.callerInfo?.hasVideo == true ? "video.fill" : "phone.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.white)
            }
            .padding(.bottom, 20)
            
            // Информация о звонящем
            VStack(spacing: 10) {
                Text(callManager.callerInfo?.callerName ?? "Клиент")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                HStack {
                    Image(systemName: callManager.callerInfo?.hasVideo == true ? "video" : "phone")
                        .font(.caption)
                    Text(callManager.callerInfo?.hasVideo == true ? "Видеозвонок" : "Аудиозвонок")
                        .font(.headline)
                }
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                )
            }
            
            Spacer()
            
            // Кнопки ответа/отклонения
            HStack(spacing: 40) {
                // Отклонить
                Button(action: {
                    callManager.declineCall()
                    presentationMode.wrappedValue.dismiss()
                }) {
                    VStack {
                        ZStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 70, height: 70)
                                .shadow(color: .red.opacity(0.5), radius: 10, x: 0, y: 5)
                            
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 30))
                                .foregroundColor(.white)
                        }
                        
                        Text("Отклонить")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                
                // Ответить
                Button(action: {
                    callManager.acceptCall()
                }) {
                    VStack {
                        ZStack {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 70, height: 70)
                                .shadow(color: .green.opacity(0.5), radius: 10, x: 0, y: 5)
                            
                            Image(systemName: "phone.fill")
                                .font(.system(size: 30))
                                .foregroundColor(.white)
                        }
                        
                        Text("Ответить")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
            .padding(.bottom, 50)
        }
    }
    
    // MARK: - Outgoing Call Content
    private var outgoingCallContent: some View {
        VStack(spacing: 30) {
            Spacer()
            
            // Пульсирующий индикатор
            ZStack {
                ForEach(0..<3) { index in
                    Circle()
                        .stroke(Color.blue.opacity(0.3 - Double(index) * 0.1), lineWidth: 2)
                        .frame(width: 100 + CGFloat(index * 40),
                               height: 100 + CGFloat(index * 40))
                }
                
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.white)
            }
            .padding(.bottom, 20)
            
            VStack(spacing: 10) {
                Text("Клиент")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Text("Исходящий вызов...")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.2))
                    )
            }
            
            Spacer()
            
            // Кнопка отмены
            Button(action: {
                callManager.endCall()
                presentationMode.wrappedValue.dismiss()
            }) {
                VStack {
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 70, height: 70)
                            .shadow(color: .red.opacity(0.5), radius: 10, x: 0, y: 5)
                        
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                    }
                    
                    Text("Отменить")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            .padding(.bottom, 50)
        }
    }
    
    // MARK: - Active Call Content
    private var activeCallContent: some View {
        ZStack {
            // Локальное видео PiP
            VStack {
                HStack {
                    Spacer()
                    if rtcManager.isVideoEnabled {
                        CustomLocalVideoView()
                            .frame(width: 120, height: 180)
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.white, lineWidth: 2)
                            )
                            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
                            .padding()
                    }
                }
                Spacer()
            }
            
            // Информация о звонке
            VStack {
                // Верхняя панель
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            
                            Text("Клиент")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        
                        Text(formattedDuration)
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    
                    Spacer()
                    
                    // Индикатор аудио маршрута
                    Button(action: { showAudioRoutes.toggle() }) {
                        HStack {
                            Image(systemName: callManager.currentAudioRoute.icon)
                            if callManager.isBluetoothAvailable {
                                Text("Bluetooth")
                                    .font(.caption)
                            }
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.2))
                        )
                    }
                }
                .padding()
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.6), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                
                Spacer()
                
                // Нижняя панель с элементами управления
                VStack(spacing: 20) {
                    // Меню аудио маршрутов
                    if showAudioRoutes {
                        audioRoutesMenu
                    }
                    
                    // Основные элементы управления
                    HStack(spacing: 30) {
                        // Mute
                        ControlButton(
                            icon: isMuted ? "mic.slash.fill" : "mic.fill",
                            color: isMuted ? .red : .blue,
                            action: toggleMute
                        )
                        
                        // Speaker/Audio Route
                        ControlButton(
                            icon: callManager.currentAudioRoute.icon,
                            color: .blue,
                            action: { callManager.toggleAudioRoute() }
                        )
                        
                        // Video toggle (если изначально видеозвонок)
                        if callManager.callerInfo?.hasVideo == true {
                            ControlButton(
                                icon: isVideoEnabled ? "video.fill" : "video.slash.fill",
                                color: isVideoEnabled ? .blue : .red,
                                action: toggleVideo
                            )
                        }
                        
                        // End call
                        ControlButton(
                            icon: "phone.down.fill",
                            color: .red,
                            isEndCall: true,
                            action: {
                                callManager.endCall()
                                presentationMode.wrappedValue.dismiss()
                            }
                        )
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }
    
    // MARK: - Audio Routes Menu
    private var audioRoutesMenu: some View {
        VStack(spacing: 12) {
            ForEach(callManager.availableAudioRoutes, id: \.self) { route in
                Button(action: {
                    switch route {
                    case .builtInSpeaker:
                        callManager.switchToSpeaker()
                    case .builtInReceiver:
                        callManager.switchToReceiver()
                    case .bluetooth, .airPods, .headphones:
                        callManager.switchToBluetooth()
                    }
                    showAudioRoutes = false
                }) {
                    HStack {
                        Image(systemName: route.icon)
                            .font(.system(size: 20))
                        
                        Text(route.rawValue)
                            .font(.system(size: 16, weight: .medium))
                        
                        Spacer()
                        
                        if route == callManager.currentAudioRoute {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.15))
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                    )
                }
            }
        }
        .padding(.horizontal, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    
    // MARK: - Computed Properties
    
    private var formattedDuration: String {
        let duration = Int(callManager.callDuration)
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60
        let seconds = duration % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
    
    // MARK: - Actions
    
    private func toggleMute() {
        isMuted.toggle()
        if let audioTrack = rtcManager.localAudioTrack {
            audioTrack.isEnabled = !isMuted
        }
    }
    
    private func toggleVideo() {
        isVideoEnabled.toggle()
        rtcManager.toggleVideo()
    }
}

// MARK: - Control Button Component
struct ControlButton: View {
    let icon: String
    let color: Color
    var isEndCall: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.2))
                        .frame(width: 60, height: 60)
                        .overlay(
                            Circle()
                                .stroke(color.opacity(0.3), lineWidth: 1)
                        )
                    
                    Image(systemName: icon)
                        .font(.system(size: isEndCall ? 24 : 22))
                        .foregroundColor(isEndCall ? .white : color)
                        .shadow(color: color.opacity(0.5), radius: 5)
                }
                
                if isEndCall {
                    Text("Завершить")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
    }
}

// MARK: - Custom Remote Video View
struct CustomRemoteVideoView: UIViewRepresentable {
    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        return view
    }
    
    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        if let track = WebRTCManager.shared.remoteVideoTrack {
            track.add(uiView)
        }
    }
}

// MARK: - Custom Local Video View
struct CustomLocalVideoView: UIViewRepresentable {
    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        return view
    }
    
    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        if let track = WebRTCManager.shared.localVideoTrack {
            track.add(uiView)
        }
    }
}
