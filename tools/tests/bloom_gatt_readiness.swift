import Foundation

@main struct GATTReadinessRegression {
    static func main() {
        var state = ESPGATTDiscoveryState()
        state.begin(["session", "version", "scan", "custom"])
        state.discovered("session", descriptors: ["session/2901"])
        state.read("session/2901")
        // Session-first callback must not start a session against an incomplete map.
        precondition(!state.finish(hasSession: true, hasVersion: false))
        state.discovered("version", descriptors: ["version/2901"])
        state.read("version/2901")
        precondition(!state.finish(hasSession: true, hasVersion: true))
        state.discovered("custom", descriptors: ["custom/2901"])
        state.discovered("scan", descriptors: ["scan/2901"])
        state.read("scan/2901")
        precondition(!state.finish(hasSession: true, hasVersion: true))
        state.read("custom/2901")
        precondition(state.finish(hasSession: true, hasVersion: true))
        // Repeated descriptor callbacks must not start Security1 a second time.
        state.read("session/2901")
        precondition(!state.finish(hasSession: true, hasVersion: true))
        // Reconnect must wait for a fresh descriptor map.
        state.begin(["session", "version"])
        precondition(!state.finish(hasSession: true, hasVersion: true))
        state.discovered("version", descriptors: ["version/2901"])
        state.discovered("session", descriptors: ["session/2901"])
        state.read("version/2901"); state.read("session/2901")
        precondition(!state.finish(hasSession: true, hasVersion: false))
        precondition(state.finish(hasSession: true, hasVersion: true))
        print("GATT readiness: session-first, out-of-order reads, once-only and reconnect passed")
    }
}
