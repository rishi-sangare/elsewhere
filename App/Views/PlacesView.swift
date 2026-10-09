import SpoofKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct PlacesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Place.lastUsed, order: .reverse) private var places: [Place]
    @Query(sort: \SavedRoute.createdAt, order: .reverse) private var routes: [SavedRoute]
    @State private var importing = false
    @State private var importError: String?

    let onTeleport: (Coordinate, String?) -> Void
    let onShow: (Coordinate, String?) -> Void
    let onStartRoute: (PlannedRoute, RouteSettings) -> Void

    private var favorites: [Place] { places.filter(\.isFavorite).sorted { $0.name < $1.name } }
    private var recents: [Place] { places.filter { !$0.isFavorite } }

    var body: some View {
        NavigationStack {
            List {
                if places.isEmpty && routes.isEmpty {
                    ContentUnavailableView("No places yet", systemImage: "star",
                                           description: Text("Drop a pin and tap Save, or import a GPX route."))
                }
                if !favorites.isEmpty {
                    Section("Favourites") { ForEach(favorites) { placeRow($0) }.onDelete { delete($0, from: favorites) } }
                }
                if !routes.isEmpty {
                    Section("Saved routes") {
                        ForEach(routes) { route in
                            Button {
                                if let planned = route.plannedRoute { onStartRoute(planned, route.settings) }
                            } label: {
                                HStack {
                                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                                        .foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading) {
                                        Text(route.name).lineLimit(1)
                                        Text("\(Int(route.speedKmh)) km/h · \(route.trafficRaw.capitalized) traffic")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "play.circle.fill").font(.title2)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) { context.delete(route) } label: { Label("Delete", systemImage: "trash") }
                                ShareLink(item: GPXFile(name: route.name, points: route.points),
                                          preview: SharePreview("\(route.name).gpx"))
                            }
                        }
                    }
                }
                if !recents.isEmpty {
                    Section("Recent") { ForEach(recents) { placeRow($0) }.onDelete { delete($0, from: recents) } }
                }
            }
            .navigationTitle("Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { importing = true } label: { Label("Import GPX", systemImage: "square.and.arrow.down") }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.gpx, .xml]) { result in
                importGPX(result)
            }
            .alert("Couldn't import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(importError ?? "") }
        }
        .presentationDetents([.medium, .large])
    }

    private func placeRow(_ place: Place) -> some View {
        HStack {
            Image(systemName: place.isFavorite ? "star.fill" : "clock")
                .foregroundStyle(place.isFavorite ? .yellow : .secondary)
            VStack(alignment: .leading) {
                Text(place.name).lineLimit(1)
                Text(place.coordinate.description).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Teleport") { place.lastUsed = .now; onTeleport(place.coordinate, place.name) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .contentShape(Rectangle())
        .onTapGesture { onShow(place.coordinate, place.name) }
        .swipeActions(edge: .leading) {
            Button { place.isFavorite.toggle() } label: {
                Label(place.isFavorite ? "Unfavourite" : "Favourite", systemImage: "star")
            }
            .tint(.yellow)
        }
    }

    private func delete(_ offsets: IndexSet, from list: [Place]) {
        for i in offsets { context.delete(list[i]) }
    }

    private func importGPX(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let points = try GPX.parse(try Data(contentsOf: url))
            let name = url.deletingPathExtension().lastPathComponent
            guard let planned = RoutePlanner.fromGPX(points, name: name) else {
                importError = "The file needs at least two different points."
                return
            }
            context.insert(SavedRoute(name: name, route: planned, settings: RouteSettings()))
        } catch {
            importError = error.localizedDescription
        }
    }
}

extension UTType {
    static let gpx = UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml
}

struct GPXFile: Transferable {
    let name: String
    let points: [Coordinate]

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .gpx) { file in GPX.export(file.points, name: file.name) }
            .suggestedFileName { "\($0.name).gpx" }
    }
}
