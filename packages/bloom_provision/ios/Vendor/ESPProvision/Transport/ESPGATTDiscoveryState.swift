import Foundation

// CoreBluetooth may return descriptor discovery and reads in any order.
// Wait for every characteristic and descriptor, then announce readiness once.
struct ESPGATTDiscoveryState {
    private var characteristics = Set<String>()
    private var descriptors = Set<String>()
    private var delivered = false
    mutating func begin(_ ids: [String]) {
        characteristics = Set(ids); descriptors.removeAll(); delivered = false
    }
    mutating func discovered(_ id: String, descriptors ids: [String]) {
        guard characteristics.remove(id) != nil else { return }
        descriptors.formUnion(ids)
    }
    mutating func read(_ id: String) { descriptors.remove(id) }
    mutating func finish(hasSession: Bool, hasVersion: Bool) -> Bool {
        guard !delivered, characteristics.isEmpty, descriptors.isEmpty,
              hasSession, hasVersion else { return false }
        delivered = true
        return true
    }
}

// Never record credentials, packet bytes, QR contents, names or network SSIDs.
enum BloomBLEDiagnostics {
    static func record(_ stage: String) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("bloom-ble-stages.log")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 65536 {
            try? FileManager.default.removeItem(at: url)
        }
        let line = "\(Date().timeIntervalSince1970) \(stage)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile(); handle.write(data)
    }
}
