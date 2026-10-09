import SpoofKit
import SwiftUI

/// The single most important piece of UI: is the phone really somewhere else?
struct StatusPill: View {
    let status: SessionStatus

    var body: some View {
        HStack(spacing: 8) {
            indicator
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1))
        .contentTransition(.opacity)
        .animation(.snappy, value: title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(title)")
    }

    @ViewBuilder private var indicator: some View {
        switch status {
        case .connecting, .active(verified: false), .reconnecting, .stopping:
            ProgressView().controlSize(.small).tint(color)
        default:
            Circle().fill(color).frame(width: 10, height: 10)
                .shadow(color: color.opacity(0.8), radius: status.isVerified ? 4 : 0)
        }
    }

    var title: String {
        switch status {
        case .idle: "Real location"
        case .connecting: "Connecting…"
        case .active(verified: false): "Confirming…"
        case .active(verified: true): "Location changed · verified"
        case .reconnecting: "Reconnecting…"
        case .lost: "Real location may be visible"
        case .stopping: "Stopping…"
        }
    }

    var color: Color {
        switch status {
        case .idle: .gray
        case .connecting, .active(verified: false), .stopping: .yellow
        case .active(verified: true): .green
        case .reconnecting: .orange
        case .lost: .red
        }
    }
}

struct AlertBanner: View {
    let message: String
    let onFix: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your real location may be visible")
                    .font(.subheadline.weight(.bold))
                Text(message)
                    .font(.caption)
                    .opacity(0.9)
                HStack {
                    Button("Diagnose", action: onFix)
                    Button("Stop", action: onStop)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .red.opacity(0.3), radius: 12, y: 4)
    }
}

struct RecoveryBanner: View {
    let intent: SessionIntent
    let onResume: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Spoofing stopped while Elsewhere was closed", systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold))
            Text("Your phone has been showing its real location since \(intent.savedAt.formatted(date: .omitted, time: .shortened)).")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Resume at \(intent.placeName ?? "last place")", action: onResume)
                    .buttonStyle(.borderedProminent)
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The "car" on the map: a dot with a heading arrow.
struct PositionMarker: View {
    let course: Double
    let moving: Bool
    let verified: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill((verified ? Color.accentColor : Color.orange).opacity(0.18))
                .frame(width: 44, height: 44)
            Circle()
                .fill(.white)
                .frame(width: 26, height: 26)
                .shadow(radius: 2)
            Image(systemName: moving ? "location.north.fill" : "circle.fill")
                .font(.system(size: moving ? 14 : 12, weight: .bold))
                .foregroundStyle(verified ? Color.accentColor : .orange)
                .rotationEffect(.degrees(moving ? course : 0))
        }
        .animation(.linear(duration: 0.25), value: course)
    }
}

struct PinMarker: View {
    var body: some View {
        Image(systemName: "mappin.circle.fill")
            .font(.system(size: 34))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color.red)
            .shadow(radius: 3)
            .padding(.bottom, 4)
    }
}
