import Foundation

/// PROTOCOL §4 —— Frame 类型。未知类型走 `.unknown`,解码不抛错(原则 2)。
enum FrameType: Decodable, Equatable {
    case auth, authOk, authErr
    case presence
    case ui, patch, action, input
    case ack, ping, pong, resume, error
    case unknown(String)

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        switch raw {
        case "auth": self = .auth
        case "auth_ok": self = .authOk
        case "auth_err": self = .authErr
        case "presence": self = .presence
        case "ui": self = .ui
        case "patch": self = .patch
        case "action": self = .action
        case "input": self = .input
        case "ack": self = .ack
        case "ping": self = .ping
        case "pong": self = .pong
        case "resume": self = .resume
        case "error": self = .error
        default: self = .unknown(raw)
        }
    }

    var wireValue: String {
        switch self {
        case .auth: return "auth"
        case .authOk: return "auth_ok"
        case .authErr: return "auth_err"
        case .presence: return "presence"
        case .ui: return "ui"
        case .patch: return "patch"
        case .action: return "action"
        case .input: return "input"
        case .ack: return "ack"
        case .ping: return "ping"
        case .pong: return "pong"
        case .resume: return "resume"
        case .error: return "error"
        case .unknown(let s): return s
        }
    }
}

/// PROTOCOL §3 —— 统一信封。字段尽量可选,缺字段不崩(原则 2)。
struct Frame: Decodable {
    let v: Int?
    let t: FrameType
    let id: String?
    let sid: String?
    let seq: Int?
    let ts: Int?
    let from: String?
    let fallbackText: String?
    let body: JSONValue?

    static func decode(_ text: String) -> Frame? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Frame.self, from: data)
    }
}
