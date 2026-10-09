import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct ElsewhereWidgets: WidgetBundle {
    var body: some Widget { SpoofLiveActivity() }
}

struct SpoofLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpoofActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HealthIcon(health: context.state.health).font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let speed = context.state.speedText {
                        Text(speed).font(.headline.monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        Text(context.state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let p = context.state.progress { ProgressView(value: p) }
                        Button(intent: StopSpoofingIntent()) {
                            Label("Stop — back to real location", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .tint(.red)
                    }
                }
            } compactLeading: {
                HealthIcon(health: context.state.health)
            } compactTrailing: {
                Text(context.state.speedText ?? "On").font(.caption.monospacedDigit())
            } minimal: {
                HealthIcon(health: context.state.health)
            }
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<SpoofActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HealthIcon(health: context.state.health).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.title).font(.headline).lineLimit(1)
                    Text(context.state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let speed = context.state.speedText {
                    Text(speed).font(.title3.weight(.bold).monospacedDigit())
                }
            }
            if let p = context.state.progress { ProgressView(value: p).tint(.blue) }
            HStack {
                Text("Since \(context.attributes.startedAt, style: .time)").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(intent: StopSpoofingIntent()) {
                    Label("Stop", systemImage: "stop.fill").font(.caption.weight(.semibold))
                }
                .tint(.red)
            }
        }
        .padding(16)
    }
}

private struct HealthIcon: View {
    let health: SpoofActivityAttributes.ContentState.Health

    var body: some View {
        switch health {
        case .verified: Image(systemName: "location.fill").foregroundStyle(.green)
        case .connecting: Image(systemName: "location").foregroundStyle(.yellow)
        case .lost: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}
