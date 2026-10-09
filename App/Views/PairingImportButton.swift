import SwiftUI
import UniformTypeIdentifiers

/// Imports the pairing file made with iLoader on a computer (AirDrop or Files).
struct PairingImportButton: View {
    var onImported: () -> Void = {}
    @State private var picking = false
    @State private var message: String?
    @State private var hasFile = PairingStore.exists

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { picking = true } label: {
                    Label(hasFile ? "Replace pairing file" : "Import pairing file", systemImage: "doc.badge.plus")
                }
                if hasFile {
                    Spacer()
                    Button("Remove", role: .destructive) {
                        PairingStore.remove()
                        hasFile = false
                    }
                    .font(.footnote)
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: [.propertyList, .xml, .data,
                                            UTType(filenameExtension: "mobiledevicepairing") ?? .data]) { result in
            do {
                try PairingStore.importFile(from: try result.get())
                hasFile = true
                message = "Imported. It stays on this iPhone only."
                onImported()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
