import Foundation
#if canImport(IDevice)
import IDevice
#endif

/// The pairing file is effectively a key to the phone's developer services.
/// It lives only in the app container: complete file protection, excluded from
/// backups, never uploaded, never logged.
enum PairingStore {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Elsewhere", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "pairing.plist")
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Validates and stores a pairing file chosen by the user.
    static func importFile(from source: URL) throws {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        try validate(data)
        var dest = url
        try? FileManager.default.removeItem(at: dest)
        try data.write(to: dest, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dest.setResourceValues(values)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    static func validate(_ data: Data) throws {
        guard !data.isEmpty else { throw BackendError("The pairing file is empty.") }
        #if canImport(IDevice)
        var handle: OpaquePointer?
        let err = data.withUnsafeBytes { buf in
            rp_pairing_file_from_bytes(buf.bindMemory(to: UInt8.self).baseAddress, UInt(data.count), &handle)
        }
        if let err {
            idevice_error_free(err)
            throw BackendError("That doesn't look like a pairing file for iOS 17.4 or later. Make a new one with iLoader.")
        }
        if let handle { rp_pairing_file_free(handle) }
        #endif
    }
}
