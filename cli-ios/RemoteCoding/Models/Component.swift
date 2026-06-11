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

/// PROTOCOL §5 —— 一条渲染用的富消息。由 `t: "ui"` 的 Frame 构造。
struct UIMessage: Identifiable {
    let id: String
    var seq: Int
    var role: String          // agent | user | system
    var root: Component
    var fallbackText: String?

    init?(frame: Frame) {
        guard case .ui = frame.t, let id = frame.id, let body = frame.body else { return nil }
        self.id = id
        self.seq = frame.seq ?? 0
        self.role = body["role"]?.stringValue ?? "agent"
        self.root = Component(json: body["root"] ?? .object([:]))
        self.fallbackText = frame.fallbackText
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
    }
}
