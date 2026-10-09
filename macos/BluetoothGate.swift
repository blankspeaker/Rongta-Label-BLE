// SPDX-License-Identifier: GPL-3.0-or-later
// Whether a scan may start. The class property is not a grant until a
// manager exists and centralManagerDidUpdateState has run.

enum BluetoothGate {
    enum Auth: Equatable {
        case notDetermined
        case restricted
        case denied
        case allowedAlways
        case unknown

        var token: String {
            switch self {
            case .notDetermined: return "notDetermined"
            case .restricted: return "restricted"
            case .denied: return "denied"
            case .allowedAlways: return "allowedAlways"
            case .unknown: return "unknown"
            }
        }
    }

    enum Radio: Equatable {
        case unknown
        case resetting
        case unsupported
        case unauthorized
        case poweredOff
        case poweredOn

        var token: String {
            switch self {
            case .unknown: return "unknown"
            case .resetting: return "resetting"
            case .unsupported: return "unsupported"
            case .unauthorized: return "unauthorized"
            case .poweredOff: return "poweredOff"
            case .poweredOn: return "poweredOn"
            }
        }
    }

    enum Step: Equatable {
        case wait
        case proceed
        case fail(String)
    }

    static let permissionDenied = "ERR Bluetooth permission denied\n"
    /// Samples of allowedAlways + unauthorized before that pair is a denial.
    /// The first state callback is often unauthorized for a moment.
    static let unauthorizedGrace = 8

    /// `stateIsLive` stays false until the delegate runs. The value sitting
    /// in `CBCentralManager.state` immediately after init is not a decision,
    /// and a denied result is never remembered for the next request.
    static func step(
        authorization: Auth,
        radio: Radio,
        stateIsLive: Bool,
        unauthorizedSamples: Int
    ) -> Step {
        if !stateIsLive {
            return .wait
        }
        switch authorization {
        case .denied, .restricted:
            return .fail(permissionDenied)
        case .notDetermined, .unknown:
            return .wait
        case .allowedAlways:
            switch radio {
            case .poweredOn:
                return .proceed
            case .poweredOff:
                return .fail("ERR Bluetooth is off\n")
            case .unsupported:
                return .fail("ERR Bluetooth is unsupported\n")
            case .unauthorized:
                if unauthorizedSamples < unauthorizedGrace {
                    return .wait
                }
                return .fail(permissionDenied)
            case .unknown, .resetting:
                return .wait
            }
        }
    }
}
