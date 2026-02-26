//
//  CommonTypes.swift
//  Whisper Call
//
//  Created by Jordan Babov on 27.02.2026.
//

import SwiftUI

// MARK: - Цветовые схемы для светлой и тёмной темы
struct AppColors {
    // Основные цвета
    static let primaryBlue = Color.blue
    static let primaryPurple = Color.purple
    static let accentGreen = Color.green
    static let accentRed = Color.red
    
    // Градиенты
    static let primaryGradient = LinearGradient(
        colors: [.blue, .purple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    // Фоны для разных режимов
    static func backgroundGradient(for colorScheme: ColorScheme) -> LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.08, blue: 0.12),
                    Color(red: 0.12, green: 0.12, blue: 0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            return LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.96, blue: 1.0),
                    Color(red: 0.98, green: 0.98, blue: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
    
    // Стеклоэффект (glassmorphism) - единый для всех элементов
    static func glassBackground(for colorScheme: ColorScheme) -> some View {
        Group {
            if colorScheme == .dark {
                Color(red: 0.15, green: 0.15, blue: 0.22).opacity(0.7)
            } else {
                Color(red: 0.95, green: 0.95, blue: 1.0).opacity(0.7)
            }
        }
        .background(.ultraThinMaterial)
    }
    
    // Цвета для сообщений
    static func incomingMessageColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ?
            Color(red: 0.25, green: 0.25, blue: 0.35).opacity(0.8) :
            Color(red: 0.9, green: 0.92, blue: 0.95).opacity(0.9)
    }
    
    static func outgoingMessageColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ?
            Color(red: 0.35, green: 0.3, blue: 0.5).opacity(0.8) :
            Color.blue.opacity(0.9)
    }
}

// MARK: - WebClientStatus
struct WebClientStatus {
    let sessionUUID: String
    let clientName: String
    let isOnline: Bool
    let lastSeen: Date?
    
    var statusText: String {
        if isOnline {
            return "online"
        } else if let lastSeen = lastSeen {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "был(а) \(formatter.localizedString(for: lastSeen, relativeTo: Date()))"
        } else {
            return "offline"
        }
    }
}

// MARK: - ScaleButtonStyle
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
