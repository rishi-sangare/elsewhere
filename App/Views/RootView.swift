import MapKit
import SpoofKit
import SwiftData
import SwiftUI

struct DroppedPin: Equatable {
    var coordinate: Coordinate
    var name: String?
}

/// One full-screen map. Tap anywhere to drop a pin; everything else lives in
/// the bottom panel, which changes with what you're doing.
struct RootView: View {
    @Environment(SpoofController.self) private var controller
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.units) private var unitsRaw = Units.metric.rawValue
    @AppStorage("onboarded") private var onboarded = false

    @State private var camera: MapCameraPosition = .userLocation(fallback: .region(.mumbai))
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var pin: DroppedPin?
    @State private var routeStart: DroppedPin?
    @State private var planning = false
    @State private var previewRoute: PlannedRoute?
    @State private var search = SearchModel()
    @State private var searchFocused = false
    @State private var follow = true
    @State private var sheet: Sheet?
    /// Screen areas covered by the top bar and bottom panel. Map taps there are
    /// ignored so pressing a button never also drops a pin underneath it.
    @State private var topBarFrame: CGRect = .zero
    @State private var panelFrame: CGRect = .zero

    enum Sheet: String, Identifiable {
        case places, settings, setup
        var id: String { rawValue }
    }

    private var units: Units { Units(rawValue: unitsRaw) ?? .metric }

    var body: some View {
        MapReader { proxy in
            Map(position: $camera) {
                UserAnnotation()
                if let route = controller.route ?? previewRoute {
                    MapPolyline(coordinates: route.path.points.map(\.cl))
                        .stroke(Color.accentColor.opacity(controller.route == nil ? 0.55 : 0.9),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }
                if let start = routeStart, planning {
                    Marker("Start", systemImage: "flag.fill", coordinate: start.coordinate.cl).tint(.green)
                }
                if let pos = controller.position, controller.mode != .idle {
                    Annotation("", coordinate: pos.cl) {
                        PositionMarker(course: controller.course, moving: controller.speed > 0.3,
                                       verified: controller.status.isVerified)
                    }
                    .annotationTitles(.hidden)
                }
                if let pin {
                    Annotation(pin.name ?? "", coordinate: pin.coordinate.cl, anchor: .bottom) { PinMarker() }
                }
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .all))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .onTapGesture(coordinateSpace: .global) { point in
                guard !topBarFrame.contains(point), !panelFrame.contains(point),
                      let c = proxy.convert(point, from: .global) else { return }
                searchFocused = false
                dropPin(Coordinate(c))
            }
            .onMapCameraChange(frequency: .onEnd) { ctx in
                visibleRegion = ctx.region
                search.bias(to: ctx.region)
            }
        }
        .ignoresSafeArea()
        .safeAreaInset(edge: .top, spacing: 0) {
            topBar.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { topBarFrame = $0 }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomPanel.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { panelFrame = $0 }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .overlay(alignment: .trailing) { mapButtons }
        .overlay(alignment: .bottomLeading) {
            if controller.mode == .joystick {
                JoystickPad { controller.joystickVector = $0 }
                    .padding(.leading, 24)
                    .padding(.bottom, 190)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .places: PlacesView(onTeleport: { c, name in sheet = nil; teleport(c, name: name) },
                                     onShow: { c, name in sheet = nil; dropPin(c, name: name); fly(to: c) },
                                     onStartRoute: { route, settings in sheet = nil; start(route, settings) })
            case .settings: SettingsView(openSetup: { sheet = .setup })
            case .setup: SetupView()
            }
        }
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { onboarded = !$0 })) {
            OnboardingView { onboarded = true }
        }
        .onChange(of: controller.position) { _, new in
            guard follow, let new, controller.mode == .route || controller.mode == .joystick else { return }
            withAnimation(.linear(duration: 0.25)) {
                camera = .camera(MapCamera(centerCoordinate: new.cl, distance: 1600, heading: 0, pitch: 0))
            }
        }
        .animation(.snappy, value: controller.alertMessage)
        .animation(.snappy, value: controller.mode)
        .animation(.snappy, value: pin)
        .animation(.snappy, value: planning)
    }

    // MARK: Top

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack {
                Button { sheet = .setup } label: { StatusPill(status: controller.displayStatus) }
                    .buttonStyle(.plain)
                Spacer()
                circleButton("star", label: "Places") { sheet = .places }
                circleButton("gearshape", label: "Settings") { sheet = .settings }
            }
            SearchField(model: search, focused: $searchFocused)
            if searchFocused && !search.query.isEmpty {
                SearchResults(model: search) { c, name in
                    searchFocused = false
                    search.clear()
                    dropPin(c, name: name)
                    fly(to: c)
                }
            }
            if let message = controller.alertMessage {
                AlertBanner(message: message, onFix: { sheet = .setup }, onStop: controller.stop)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let intent = controller.pendingRecovery, controller.mode == .idle {
                RecoveryBanner(intent: intent,
                               onResume: { controller.resume(intent); fly(to: intent.coordinate) },
                               onDismiss: { controller.pendingRecovery = nil })
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var mapButtons: some View {
        VStack(spacing: 10) {
            if controller.mode != .idle {
                circleButton(follow ? "location.fill" : "location", label: "Follow") {
                    follow.toggle()
                    if follow, let p = controller.position { fly(to: p) }
                }
            } else {
                circleButton("location", label: "My location") {
                    withAnimation { camera = .userLocation(fallback: camera) }
                }
            }
            circleButton(controller.mode == .joystick ? "gamecontroller.fill" : "gamecontroller", label: "Joystick") {
                if controller.mode == .joystick { controller.stop() } else { startJoystick() }
            }
        }
        .padding(.trailing, 16)
        .padding(.bottom, 120)
    }

    // MARK: Bottom

    @ViewBuilder private var bottomPanel: some View {
        Group {
            if controller.mode == .route {
                PlaybackPanel(units: units, onSave: saveCurrentRoute)
            } else if planning, let destination = pin {
                RoutePlannerPanel(
                    start: routeStart ?? startCandidate,
                    destination: destination,
                    units: units,
                    preview: $previewRoute,
                    onCancel: { planning = false; previewRoute = nil; routeStart = nil },
                    onStart: { route, settings in start(route, settings) }
                )
            } else if let pin {
                PinPanel(pin: pin, units: units,
                         distanceFromCurrent: controller.position.map { Geo.distance($0, pin.coordinate) },
                         onTeleport: { teleport(pin.coordinate, name: pin.name) },
                         onRoute: { planning = true },
                         onSetStart: { routeStart = pin; self.pin = nil },
                         onSave: { savePlace(pin) },
                         onClose: { self.pin = nil })
            } else if controller.mode == .teleport || controller.mode == .joystick {
                ActivePanel(units: units)
            } else {
                BrowsePanel(onPick: { place in dropPin(place.coordinate, name: place.name); fly(to: place.coordinate) },
                            routeStart: routeStart, onClearStart: { routeStart = nil })
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: Actions

    private var startCandidate: DroppedPin {
        if let p = controller.position { return DroppedPin(coordinate: p, name: "Current position") }
        if let real = CLLocationManager().location?.coordinate {
            return DroppedPin(coordinate: Coordinate(real), name: "My location")
        }
        let center = visibleRegion?.center ?? MKCoordinateRegion.mumbai.center
        return DroppedPin(coordinate: Coordinate(center), name: "Map centre")
    }

    private func dropPin(_ c: Coordinate, name: String? = nil) {
        guard !planning else {
            // While planning, a tap moves the destination.
            pin = DroppedPin(coordinate: c, name: name)
            resolveName(c)
            return
        }
        pin = DroppedPin(coordinate: c, name: name)
        Haptics.tap()
        if name == nil { resolveName(c) }
    }

    private func resolveName(_ c: Coordinate) {
        Task {
            let name = await Geocoder.name(for: c)
            if pin?.coordinate == c, pin?.name == nil { pin?.name = name }
        }
    }

    private func teleport(_ c: Coordinate, name: String?) {
        controller.teleport(to: c, name: name)
        recordRecent(c, name: name)
        pin = nil
        planning = false
        previewRoute = nil
    }

    private func start(_ route: PlannedRoute, _ settings: RouteSettings) {
        controller.startRoute(route, settings: settings)
        recordRecent(route.destination, name: route.destinationName)
        planning = false
        previewRoute = nil
        pin = nil
        routeStart = nil
        follow = true
    }

    private func startJoystick() {
        let c = controller.position ?? pin?.coordinate ?? Coordinate(visibleRegion?.center ?? MKCoordinateRegion.mumbai.center)
        controller.startJoystick(at: c, mode: .walk)
        pin = nil
        follow = true
    }

    private func fly(to c: Coordinate) {
        withAnimation(.easeInOut(duration: 0.8)) {
            camera = .camera(MapCamera(centerCoordinate: c.cl, distance: 2500))
        }
    }

    private func savePlace(_ pin: DroppedPin) {
        let name = pin.name ?? pin.coordinate.description
        context.insert(Place(name: name, coordinate: pin.coordinate, isFavorite: true))
        Haptics.success()
    }

    private func recordRecent(_ c: Coordinate, name: String?) {
        let all = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        if let existing = all.first(where: { Geo.distance($0.coordinate, c) < 25 }) {
            existing.lastUsed = .now
        } else {
            context.insert(Place(name: name ?? c.description, coordinate: c))
        }
        let recents = all.filter { !$0.isFavorite }.sorted { $0.lastUsed > $1.lastUsed }
        for old in recents.dropFirst(20) { context.delete(old) }
    }

    private func saveCurrentRoute() {
        guard let route = controller.route, let settings = controller.routeSettings else { return }
        context.insert(SavedRoute(name: route.destinationName ?? "Route \(Date().formatted(date: .abbreviated, time: .shortened))",
                                  route: route, settings: settings))
        Haptics.success()
    }

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

extension MKCoordinateRegion {
    static let mumbai = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 19.0760, longitude: 72.8777),
        span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
    )
}
