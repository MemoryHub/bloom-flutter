import Flutter
import Foundation
import CoreBluetooth
import CryptoKit

public final class BloomProvisionPlugin: NSObject, FlutterPlugin, ESPDeviceConnectionDelegate {
    private var devices: [String: ESPDevice] = [:]
    private var selected: ESPDevice?
    private var pending: FlutterResult?
    private var generation = 0
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = BloomProvisionPlugin()
        let channel = FlutterMethodChannel(name: "bloom/provision", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
        ESPProvisionManager.shared.enableLogs(false)
    }
    private func finish(_ value: Any?, _ error: String? = nil, _ current: Int) {
        DispatchQueue.main.async {
            guard current == self.generation, let result = self.pending else { return }
            self.pending = nil
            if let error = error {
                BloomBLEDiagnostics.record("operation_failed_" + error)
                result(FlutterError(code: error, message: error, details: nil))
            }
            else { result(value) }
        }
    }
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "sign_admin" {
            guard let args = call.arguments as? [String: Any], let key = args["key"] as? String,
                  key.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let message = args["message"] as? String, message.utf8.count <= 256 else {
                result(FlutterError(code: "local_admin_denied", message: "local_admin_denied", details: nil)); return
            }
            do {
                let bytes = stride(from: 0, to: 64, by: 2).map { offset -> UInt8 in
                    let begin = key.index(key.startIndex, offsetBy: offset)
                    return UInt8(key[begin..<key.index(begin, offsetBy: 2)], radix: 16)!
                }
                let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(bytes))
                let signature = try privateKey.signature(for: Data(message.utf8))
                result(signature.derRepresentation.base64EncodedString())
            } catch { result(FlutterError(code: "local_admin_denied", message: "local_admin_denied", details: nil)) }
            return
        }
        if call.method == "disconnect" {
            generation += 1
            selected?.disconnect(); selected = nil
            ESPProvisionManager.shared.stopESPDevicesSearch()
            pending?(FlutterError(code: "cancelled", message: "cancelled", details: nil)); pending = nil
            result(nil); return
        }
        if call.method == "settings" {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            result(nil); return
        }
        guard pending == nil else { result(FlutterError(code: "busy", message: "busy", details: nil)); return }
        pending = result; generation += 1; let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { self.finish(nil, "timeout", current) }
        let args = call.arguments as? [String: Any] ?? [:]
        BloomBLEDiagnostics.record("operation_" + call.method)
        switch call.method {
        case "scan":
            // A failed custom operation can leave the previous ATT link alive,
            // suppressing advertising. Release it before a fresh discovery.
            selected?.disconnect(); selected = nil
            ESPProvisionManager.shared.stopESPDevicesSearch()
            devices = [:]
            ESPProvisionManager.shared.searchESPDevices(devicePrefix: "BLOOM_", transport: .ble, security: .secure) { list, error in
                guard current == self.generation else { return }
                if let error = error {
                    switch error {
                    case .espDeviceNotFound:
                        BloomBLEDiagnostics.record("scan_empty")
                        self.finish([], nil, current)
                    case .bluetoothUnavailable(let state):
                        let code: String
                        switch state {
                        case .poweredOff: code = "bluetooth_off"
                        case .unauthorized: code = "permission_denied"
                        case .unsupported: code = "bluetooth_unsupported"
                        default: code = "bluetooth_initializing"
                        }
                        self.finish(nil, code, current)
                    default: self.finish(nil, "bluetooth_scan_failed", current)
                    }
                    return
                }
                guard let list = list else { self.finish([], nil, current); return }
                for device in list where device.name.range(of: "^BLOOM_[A-F0-9]{12}$", options: .regularExpression) != nil { self.devices[device.name] = device }
                self.finish(self.devices.keys.sorted().map { name -> [String: Any] in
                    let data = self.devices[name]?.advertisementData?[CBAdvertisementDataManufacturerDataKey] as? Data
                    let busy = data?.count == 3 && data?[0] == 0xff && data?[1] == 0xff && data?[2] == 1
                    return ["ble_name": name, "busy": busy]
                }, nil, current)
            }
        case "connect":
            guard let name = args["ble_name"] as? String, let pop = args["pop"] as? String, let device = devices[name] else { finish(nil, "device_not_found", current); return }
            selected?.disconnect(); selected = device; device.proofOfPossession = pop; device.security = .secure
            device.connect(delegate: self) { state in
                switch state {
                case .connected:
                    BloomBLEDiagnostics.record("security_session_ready")
                    self.finish(true, nil, current)
                case .failedToConnect(let error):
                    BloomBLEDiagnostics.record("session_error_\(error.code)")
                    switch error {
                    case .bleFailedToConnect: self.finish(nil, "bluetooth_connection_failed", current)
                    case .versionInfoError: self.finish(nil, "bluetooth_service_failed", current)
                    default: self.finish(nil, "identity_verification_failed", current)
                    }
                default: self.finish(nil, "disconnected", current)
                }
            }
        case "networks":
            guard let device = selected else { finish(nil, "disconnected", current); return }
            device.scanWifiList { networks, error in
                if let error = error {
                    BloomBLEDiagnostics.record("wifi_scan_error_\(error.code)")
                    if case .emptyResultCount = error {
                        BloomBLEDiagnostics.record("wifi_scan_empty")
                        self.finish([], nil, current)
                    } else { self.finish(nil, "wifi_scan_failed", current) }
                    return
                }
                let networks = networks ?? []
                BloomBLEDiagnostics.record("wifi_scan_count_\(networks.count)")
                let data: [[String: Any]] = networks.map { ["ssid": $0.ssid, "rssi": Int($0.rssi), "auth": $0.auth.rawValue] }
                self.finish(data, nil, current)
            }
        case "data":
            guard let device = selected, let text = args["json"] as? String, let data = text.data(using: .utf8) else { finish(nil, "disconnected", current); return }
            device.sendData(path: "bloom-setup", data: data) { response, error in
                guard let response = response, error == nil, let text = String(data: response, encoding: .utf8) else { self.finish(nil, "communication_failed", current); return }
                self.finish(text, nil, current)
            }
        default: finish(nil, "unsupported_method", current)
        }
    }
    public func getProofOfPossesion(forDevice device: ESPDevice, completionHandler: @escaping (String) -> Void) { completionHandler(device.proofOfPossession ?? "") }
    public func getUsername(forDevice device: ESPDevice, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
}
