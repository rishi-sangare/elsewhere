import MapKit
import SpoofKit
import SwiftData
import SwiftUI

/// Rounded material card used by every bottom panel.
struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 18, y: 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Search

struct SearchField: View {
    @Bindable var model: SearchModel
    @Binding var focused: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search a place or paste coordinates", text: $model.query)
                .focused($isFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !model.query.isEmpty {
                Button { model.clear() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
        .onChange(of: isFocused) { _, v in focused = v }
        .onChange(of: focused) { _, v in if !v { isFocused = false } }
    }
}

struct SearchResults: View {
    let model: SearchModel
    let onPick: (Coordinate, String?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let c = model.pastedCoordinate {
                row(icon: "scope", title: "Go to coordinates", subtitle: c.description) { onPick(c, nil) }
            }
            ForEach(model.suggestions, id: \.self) { s in
                row(icon: "mappin.and.ellipse", title: s.title, subtitle: s.subtitle) {
                    Task { if let (c, name) = await model.resolve(s) { onPick(c, name) } }
                }
            }
            if model.suggestions.isEmpty && model.pastedCoordinate == nil {
                Text("Keep typing…").font(.footnote).foregroundStyle(.secondary).padding()
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Browse (nothing selected)

struct BrowsePanel: View {
    @Query(filter: #Predicate<Place> { $0.isFavorite }, sort: \Place.name) private var favorites: [Place]
    let onPick: (Place) -> Void
    let routeStart: DroppedPin?
    let onClearStart: () -> Void

    var body: some View {
        PanelCard {
            HStack(spacing: 12) {
                Image(systemName: "hand.tap.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tap anywhere on the map").font(.headline)
                    Text("Then teleport there, or drive there at your own speed.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let routeStart {
                HStack {
                    Label("Route starts at \(routeStart.name ?? routeStart.coordinate.description)", systemImage: "flag.fill")
                        .font(.footnote).foregroundStyle(.green).lineLimit(1)
                    Spacer()
                    Button("Clear", action: onClearStart).font(.footnote)
                }
            }
            if !favorites.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(favorites) { place in
                            Button { onPick(place) } label: {
                                Label(place.name, systemImage: "star.fill")
                                    .font(.footnote.weight(.medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Pin selected

struct PinPanel: View {
    let pin: DroppedPin
    let units: Units
    let distanceFromCurrent: Double?
    let onTeleport: () -> Void
    let onRoute: () -> Void
    let onSetStart: () -> Void
    let onSave: () -> Void
    let onClose: () -> Void

    var body: some View {
        PanelCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(pin.name ?? "Dropped pin")
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .redacted(reason: pin.name == nil ? .placeholder : [])
                    Text(pin.coordinate.description)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let d = distanceFromCurrent {
                        Text("\(Format.distance(d, units: units)) from current position")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.footnote.weight(.bold))
                        .frame(width: 30, height: 30).background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            HStack(spacing: 10) {
                Button(action: onTeleport) {
                    Label("Teleport", systemImage: "location.fill.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(action: onRoute) {
                    Label("Drive here", systemImage: "car.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            HStack(spacing: 18) {
                Button(action: onSetStart) { Label("Start route here", systemImage: "flag") }
                Button(action: onSave) { Label("Save", systemImage: "star") }
            }
            .font(.footnote)
        }
    }
}

// MARK: - Route planner

struct RoutePlannerPanel: View {
    let start: DroppedPin
    let destination: DroppedPin
    let units: Units
    @Binding var preview: PlannedRoute?
    let onCancel: () -> Void
    let onStart: (PlannedRoute, RouteSettings) -> Void

    @State private var settings = RouteSettings()
    @State private var loading = false
    @State private var estimate: TimeInterval?

    var body: some View {
        PanelCard {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drive to \(destination.name ?? "pin")").font(.headline).lineLimit(1)
                    Text("from \(start.name ?? start.coordinate.description)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Cancel", action: onCancel).font(.subheadline)
            }

            Picker("Mode", selection: $settings.mode) {
                Label("Walk", systemImage: "figure.walk").tag(TravelMode.walk)
                Label("Cycle", systemImage: "bicycle").tag(TravelMode.cycle)
                Label("Drive", systemImage: "car.fill").tag(TravelMode.drive)
                Label("Custom", systemImage: "slider.horizontal.3").tag(TravelMode.custom)
            }
            .pickerStyle(.segmented)
            .onChange(of: settings.mode) { old, new in
                if new != .custom { settings.speedKmh = new.defaultSpeedKmh }
                if (old == .walk || old == .cycle) != (new == .walk || new == .cycle) { plan() }
                estimateTime()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Speed").font(.subheadline)
                    Spacer()
                    Text(Format.speedValue(kmh: settings.speedKmh, units: units))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
                Slider(value: $settings.speedKmh, in: 1...200, step: 1) { editing in
                    if !editing { estimateTime() }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Traffic").font(.subheadline)
                Picker("Traffic", selection: $settings.traffic) {
                    ForEach(TrafficLevel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.traffic) { estimateTime() }
            }

            HStack {
                Menu {
                    Picker("Repeat", selection: $settings.repeatMode) {
                        ForEach(RepeatMode.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label(settings.repeatMode.title, systemImage: "repeat").font(.footnote)
                }
                Spacer()
                if loading {
                    ProgressView().controlSize(.small)
                } else if let preview {
                    Text(summary(preview)).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if preview?.isStraightLine == true {
                Label("No road route found — will move in a straight line.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            Button {
                if let preview { onStart(preview.named(destination.name), settings) }
            } label: {
                Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(preview == nil || loading)
        }
        .task(id: destination.coordinate) { plan() }
        .task(id: start.coordinate) { plan() }
    }

    private func summary(_ route: PlannedRoute) -> String {
        var s = Format.distance(route.distance, units: units)
        if let estimate { s += " · ~\(Format.duration(estimate))" }
        return s
    }

    private func plan() {
        loading = true
        let from = start.coordinate, to = destination.coordinate, mode = settings.mode, name = destination.name
        Task {
            let route = await RoutePlanner.plan(from: from, to: to, mode: mode, destinationName: name)
            preview = route
            loading = false
            estimateTime()
        }
    }

    private func estimateTime() {
        guard let route = preview else { estimate = nil; return }
        let player = RoutePlayer(path: route.path, intersections: route.junctions,
                                 profile: .preset(settings.mode, speedKmh: settings.speedKmh, jitter: false),
                                 traffic: settings.traffic, seed: 1)
        Task.detached(priority: .userInitiated) {
            let t = player.estimatedRemainingTime()
            await MainActor.run { estimate = t }
        }
    }
}

// MARK: - Route playing

struct PlaybackPanel: View {
    @Environment(SpoofController.self) private var controller
    let units: Units
    let onSave: () -> Void
    @State private var scrub: Double?
    @State private var saved = false

    var body: some View {
        PanelCard {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.headline).lineLimit(1)
                    Text(subline).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Format.speed(controller.speed, units: units))
                    .font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.default, value: Int(controller.speed * 3.6))
            }

            Slider(value: Binding(
                get: { scrub ?? controller.progress },
                set: { scrub = $0 }
            ), in: 0...1) { editing in
                if !editing, let s = scrub { controller.seek(to: s); scrub = nil }
            }
            .tint(Color.accentColor)

            HStack(spacing: 16) {
                Button { controller.togglePause() } label: {
                    Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                        .font(.title2).frame(width: 52, height: 52)
                        .background(Color.accentColor, in: Circle()).foregroundStyle(.white)
                }
                .accessibilityLabel(controller.isPaused ? "Resume" : "Pause")
                Button(role: .destructive) { controller.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.title3).frame(width: 44, height: 44)
                        .background(Color.red.opacity(0.15), in: Circle()).foregroundStyle(.red)
                }
                .accessibilityLabel("Stop and return to real location")
                Spacer()
                speedMenu
                trafficMenu
                rateMenu
            }
            .buttonStyle(.plain)

            HStack {
                if let s = controller.routeSettings, s.repeatMode != .once {
                    Label(s.repeatMode.title, systemImage: "repeat").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(saved ? "Saved" : "Save route") { onSave(); saved = true }
                    .font(.caption).disabled(saved)
            }
        }
    }

    private var headline: String {
        let name = controller.placeName ?? "destination"
        if controller.arrived { return "Arrived at \(name)" }
        if controller.isPaused { return "Paused · \(name)" }
        return "To \(name)"
    }

    private var subline: String {
        if controller.arrived { return "Holding position. Stop to return to your real location." }
        if controller.dwellRemaining > 0 { return "Stopped in traffic · \(Int(controller.dwellRemaining.rounded(.up))) s" }
        var parts = [Format.distance(controller.remainingDistance, units: units) + " left"]
        if let t = controller.remainingTime { parts.append("ETA \(Format.eta(t))") }
        return parts.joined(separator: " · ")
    }

    private var speedMenu: some View {
        Menu {
            ForEach([5.0, 15, 30, 40, 60, 80, 100, 120], id: \.self) { kmh in
                Button(Format.speedValue(kmh: kmh, units: units)) { controller.updateRoute(speedKmh: kmh) }
            }
        } label: {
            chip(Format.speedValue(kmh: controller.routeSettings?.speedKmh ?? 40, units: units), icon: "speedometer")
        }
    }

    private var trafficMenu: some View {
        Menu {
            ForEach(TrafficLevel.allCases) { level in
                Button(level.title) { controller.updateRoute(traffic: level) }
            }
        } label: {
            chip(controller.routeSettings?.traffic.title ?? "Traffic", icon: "car.2.fill")
        }
    }

    private var rateMenu: some View {
        Menu {
            ForEach([1.0, 2, 5, 10], id: \.self) { r in
                Button("\(Int(r))×") { controller.playbackRate = r }
            }
        } label: {
            chip("\(Int(controller.playbackRate))×", icon: "forward.fill")
        }
    }

    private func chip(_ text: String, icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.footnote)
            Text(text).font(.caption2.weight(.medium)).lineLimit(1)
        }
        .frame(minWidth: 52)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Teleported / joystick

struct ActivePanel: View {
    @Environment(SpoofController.self) private var controller
    let units: Units

    var body: some View {
        PanelCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.mode == .joystick ? "Joystick" : (controller.placeName ?? "Teleported"))
                        .font(.title3.weight(.semibold)).lineLimit(1)
                    if let p = controller.position {
                        Text(p.description).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let started = controller.startedAt {
                        Text("Since \(started.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if controller.mode == .joystick {
                    Text(Format.speed(controller.speed, units: units))
                        .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
                }
            }
            Text(controller.mode == .joystick
                 ? "Drag the stick to walk around. Tap the map to teleport somewhere else."
                 : "Every app now sees this location. Tap the map to move, or pick a pin and drive.")
                .font(.footnote).foregroundStyle(.secondary)
            Button(role: .destructive) { controller.stop() } label: {
                Label("Stop — back to real location", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
        }
    }
}

// MARK: - Joystick

struct JoystickPad: View {
    let onChange: (CGVector) -> Void
    @State private var offset: CGSize = .zero
    private let radius: CGFloat = 64

    var body: some View {
        ZStack {
            Circle().fill(.regularMaterial).frame(width: radius * 2, height: radius * 2)
                .overlay(Circle().strokeBorder(.secondary.opacity(0.3)))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            Circle().fill(Color.accentColor).frame(width: 52, height: 52)
                .shadow(radius: 3)
                .offset(offset)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    var v = g.translation
                    let len = hypot(v.width, v.height)
                    if len > radius { v = CGSize(width: v.width / len * radius, height: v.height / len * radius) }
                    offset = v
                    onChange(CGVector(dx: v.width / radius, dy: -v.height / radius))
                }
                .onEnded { _ in
                    withAnimation(.spring(duration: 0.25)) { offset = .zero }
                    onChange(.zero)
                }
        )
        .accessibilityLabel("Joystick")
    }
}
