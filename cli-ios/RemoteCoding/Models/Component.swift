import Foundation

/// PROTOCOL §6 —— 交互组件携带的动作。
struct ComponentAction: Equatable {
    let id: String
    let value: JSONValue?

    init?(json: JSONValue?) {
        guard let json, let id = json["id"]?.stringValue else { return nil }
        self.id = id
        self.value = json["value"]
    }
}

/// PROTOCOL §5 —— 组件树节点。`type` 是自由字符串,未知类型在渲染层兜底(不在解码层报错)。
struct Component: Identifiable {
    let id = UUID()
    let type: String
    let cid: String?
    let props: JSONValue
    let children: [Component]
    let action: ComponentAction?

    init(json: JSONValue) {
        self.type = json["type"]?.stringValue ?? "unknown"
        self.cid = json["cid"]?.stringValue
        self.props = json["props"] ?? .object([:])
        self.children = json["children"]?.arrayValue?.map { Component(json: $0) } ?? []
        self.action = ComponentAction(json: json["action"])
    }
}

/// 暂存待发送的一张图片(已编码,可直接入帧/回显)。
struct StagedImagePayload {
    let data: String   // base64 JPEG
    let ext: String    // "jpg"
    let name: String   // 展示文件名
    let kind: String   // "JPEG"
    let size: String   // "1.2 MB"
}

/// PROTOCOL §5 —— 一条渲染用的富消息。由 `t: "ui"` 的 Frame 构造。
struct UIMessage: Identifiable {
    let id: String
    var seq: Int
    var role: String          // agent | user | system
    var root: Component
    var fallbackText: String?
    var time: String?         // 消息时间(HH:mm,首次出现时刻,由 agent 下发)

    init?(frame: Frame) {
        guard case .ui = frame.t, let id = frame.id, let body = frame.body else { return nil }
        self.id = id
        self.seq = frame.seq ?? 0
        self.role = body["role"]?.stringValue ?? "agent"
        self.root = Component(json: body["root"] ?? .object([:]))
        self.fallbackText = frame.fallbackText
        self.time = body["time"]?.stringValue
    }

    /// 本地构造一条用户文本消息(用户在输入框发送时)。
    init(localUserText text: String) {
        self.id = UUID().uuidString
        self.seq = .max
        self.role = "user"
        self.root = Component(json: .object([
            "type": .string("text"),
            "props": .object(["text": .string(text)])
        ]))
        self.fallbackText = text
        self.time = Self.hhmm.string(from: Date())
    }

    /// 本地构造一条图文消息(手机发送图片时的即时回显,与 agent 的 photomsg 同构)。
    init(localUserImages images: [StagedImagePayload], text: String) {
        self.id = UUID().uuidString
        self.seq = .max
        self.role = "user"
        var props: [String: JSONValue] = [
            "images": .array(images.map { .object([
                "data": .string($0.data), "name": .string($0.name),
                "kind": .string($0.kind), "size": .string($0.size)
            ]) }),
            "time": .string(Self.hhmm.string(from: Date()))
        ]
        if !text.isEmpty { props["text"] = .string(text) }
        self.root = Component(json: .object(["type": .string("photomsg"), "props": .object(props)]))
        self.fallbackText = text.isEmpty ? "图片" : text
        self.time = Self.hhmm.string(from: Date())
    }

    private static let hhmm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}
