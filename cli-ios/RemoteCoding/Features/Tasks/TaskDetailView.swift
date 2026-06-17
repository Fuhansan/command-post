import SwiftUI
import PhotosUI

/// 屏 2 —— 会话详情(对话流)。每条消息 = 左侧头像 + 悬浮内容卡;用户输入靠右蓝气泡。
/// 内容全部来自该 `sid` 会话的实时下行(agent 下发的组件树)。
struct TaskDetailView: View {
    let sessionId: String
    @EnvironmentObject private var relay: RelayClient
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var showEndConfirm = false
    @State private var stagedImages: [UIImage] = []          // 暂存待发送的图片
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showLibrary = false
    @State private var showCamera = false

    private var session: RelaySession? { relay.session(id: sessionId) }

    /// 渲染顺序:按 agent 下发的逻辑序号 ord 排(同 ord 保持到达顺序,本地刚发的 .max 排末尾)。
    /// ForEach 与「滚到底」都用它 —— 否则滚到到达顺序的 last 会与视觉 last 错位,底部被盖。
    private var orderedMessages: [UIMessage] {
        guard let msgs = session?.messages else { return [] }
        return msgs.enumerated().sorted {
            $0.element.ord != $1.element.ord ? $0.element.ord < $1.element.ord : $0.offset < $1.offset
        }.map { $0.element }
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                navBar
                GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView {
                            // LazyVStack:长会话只构建/渲染可见消息行,避免一次性建出全部气泡导致卡顿。
                            LazyVStack(spacing: 14) {
                                sessionHeader
                                if session?.hasMore == true {
                                    Button { relay.loadMoreMessages(sessionId: sessionId) } label: {
                                        Label("加载更早消息", systemImage: "arrow.up.circle")
                                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.blue)
                                    }
                                    .padding(.vertical, 4)
                                }
                                if !orderedMessages.isEmpty {
                                    ForEach(orderedMessages) { msg in
                                        messageRow(msg).id(msg.id)
                                    }
                                } else if session?.status != "working" {
                                    emptyState
                                }
                                if session?.status == "working" {
                                    TypingIndicatorRow().id("typing")
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            // 撑满视口且顶部对齐:消息少时头部贴顶,不随 bottom 锚点沉底
                            .frame(minHeight: geo.size.height, alignment: .top)
                        }
                        .scrollDismissesKeyboard(.interactively)   // 下拉消息区即收键盘
                        .dismissKeyboardOnTap()                    // 点击消息区空白也收键盘
                        .defaultScrollAnchor(.bottom)   // 进入页面即定位到最新消息(聊天惯例)
                        // 瞬时定位到底部(不用 withAnimation):发消息/收消息直接落底,
                        // 不再「动画地从上往下扫一遍」。滚到**视觉**最后一条(ord 排序后)。
                        // 只在「底部新增消息」时跟随落底;「加载更早」是往上插入(末条 id 不变)
                        // → 不触发,避免把用户从正在看的位置弹回底部。
                        .onChange(of: orderedMessages.last?.id) { _, _ in
                            if session?.status == "working" {
                                proxy.scrollTo("typing", anchor: .bottom)
                            } else if let last = orderedMessages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                        .onChange(of: session?.status ?? "") { _, st in
                            if st == "working" {
                                proxy.scrollTo("typing", anchor: .bottom)
                            }
                        }
                        // 进入即「瞬间」落底:延到布局完成后无动画跳到最后一条,
                        // 不再肉眼可见地从顶部滚到底部(长会话尤其明显)。
                        .onAppear {
                            DispatchQueue.main.async {
                                if session?.status == "working" {
                                    proxy.scrollTo("typing", anchor: .bottom)
                                } else if let last = orderedMessages.last {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                inputBar
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("结束任务", isPresented: $showEndConfirm, titleVisibility: .visible) {
            Button("结束任务(关闭电脑端会话)", role: .destructive) {
                relay.endSession(sessionId: sessionId)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将终止电脑上对应的 Claude Code 会话进程,任务从列表移除。")
        }
        .onChange(of: session == nil) { _, gone in
            if gone { dismiss() }   // 会话被移除(结束/异常退出)→ 自动返回列表
        }
    }

    /// 一条消息:agent → [头像 + 内容];工具 chip 紧凑无头像;user → 右对齐气泡。
    /// 下方附小字时间(toolchip 紧凑不加;photomsg 卡内自带)。
    @ViewBuilder
    private func messageRow(_ msg: UIMessage) -> some View {
        let content = ComponentView(component: msg.root)
            .environment(\.onComponentAction) { relay.sendAction($0, for: msg.id, sessionId: sessionId) }
        let showTime = msg.time != nil && msg.root.type != "photomsg"
        if msg.role == "user" {
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 0) { Spacer(minLength: 44); content }   // 用户内容统一右对齐
                HStack(spacing: 4) {
                    if showTime { timeLabel(msg.time!) }
                    statusLabel(msg)
                }
            }
        } else if msg.root.type == "toolchip" {
            content.padding(.leading, 44)   // 缩进对齐头像后的内容
        } else {
            HStack(alignment: .top, spacing: 10) {
                let style = messageAvatarStyle(for: msg.root)
                MessageAvatar(icon: style.icon, colors: style.colors)
                VStack(alignment: .leading, spacing: 3) {
                    content.frame(maxWidth: .infinity, alignment: .leading)
                    if showTime { timeLabel(msg.time!) }
                }
            }
        }
    }

    private func timeLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 10)).foregroundStyle(Theme.textTer)
    }

    /// 投递状态:⏳发送中 / ✓已到服务器 / ✓✓电脑端已收 / 失败(点按重发)。
    @ViewBuilder
    private func statusLabel(_ msg: UIMessage) -> some View {
        switch msg.status {
        case .sending:
            Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(Theme.textTer)
        case .sent:
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTer)
        case .delivered:
            ZStack(alignment: .leading) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark").offset(x: 4)
            }
            .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.blue)
            .padding(.trailing, 4)
        case .failed:
            Button {
                relay.retryUpstream(messageId: msg.id, sessionId: sessionId)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.arrow.circlepath").font(.system(size: 11))
                    Text("重试").font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(Theme.coral)
            }
        case nil:
            EmptyView()
        }
    }

    private var navBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
            }
            Text(session?.title ?? "会话").font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text).lineLimit(1)
            Spacer()
            Menu {
                Button(role: .destructive) {
                    showEndConfirm = true
                } label: {
                    Label("结束任务", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
                    .frame(width: 36, height: 36, alignment: .trailing)   // 扩大点按区
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// 顶部只放一个可复制的 session id(点一下复制完整 id),不再占一大块会话卡。
    private var sessionHeader: some View {
        let sid = (session?.agentSessionId.isEmpty == false) ? (session?.agentSessionId ?? "") : (session?.id ?? "")
        return Button {
            UIPasteboard.general.string = sid
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "number").font(.system(size: 10))
                Text(sid.isEmpty ? "无 id" : sid)
                    .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "doc.on.doc").font(.system(size: 10))
            }
            .foregroundStyle(Theme.textSec)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.textTer.opacity(0.14)).clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "ellipsis.bubble").font(.system(size: 34)).foregroundStyle(Theme.textTer)
            Text("等待下发内容…").font(.system(size: 14)).foregroundStyle(Theme.textSec)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            commandPopup
            if !stagedImages.isEmpty { stagingStrip }
            HStack(spacing: 10) {
                Menu {
                    Button { showLibrary = true } label: { Label("相册选图", systemImage: "photo.on.rectangle") }
                    Button { showCamera = true } label: { Label("拍照", systemImage: "camera") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.textSec)
                        .frame(width: 38, height: 46)
                }
                TextField("", text: $draft,
                          prompt: Text(stagedImages.isEmpty ? "输入指令…" : "配上说明文字(可选)…")
                              .foregroundColor(Theme.textTer))
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Theme.field)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Theme.blueBtn)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .photosPicker(isPresented: $showLibrary, selection: $pickerItems,
                      maxSelectionCount: 4, matching: .images)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let ui = UIImage(data: data) {
                        stagedImages.append(ui)
                    }
                }
                pickerItems = []
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in stagedImages.append(img) }
                .ignoresSafeArea()
        }
    }

    /// 暂存框:已选图片缩略图横排,可单张移除;发送时与文字合并为一条消息。
    /// 输入「/」时,在输入框上方弹出匹配的快捷指令气泡(命令+说明);点一个直接发送。
    /// 不输「/」就不显示,不占地方。指令集按会话的 CLI 类型(claude/codex)取。
    @ViewBuilder
    private var commandPopup: some View {
        let q = draft.trimmingCharacters(in: .whitespaces)
        if q.hasPrefix("/"),
           let cmds = session.flatMap({ CLIKind.by(id: $0.cli) })?.quickCommands {
            let matches = cmds.filter { $0.cmd.hasPrefix(q) }
            if !matches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(matches) { c in
                        Button {
                            relay.sendInput(text: c.cmd, sessionId: sessionId)
                            draft = ""
                        } label: {
                            HStack(spacing: 10) {
                                Text(c.cmd)
                                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Theme.text)
                                Text(c.desc)
                                    .font(.system(size: 12)).foregroundStyle(Theme.textSec)
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if c.id != matches.last?.id { Divider().overlay(Theme.stroke) }
                    }
                }
                .background(Theme.field)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
                .padding(.horizontal, 12).padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    private var stagingStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(stagedImages.enumerated()), id: \.offset) { i, img in
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                stagedImages.remove(at: i)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 17))
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .offset(x: 6, y: -6)
                        }
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.trailing, 6)
        }
    }

    private func send() {
        let text = draft
        if stagedImages.isEmpty {
            relay.sendInput(text: text, sessionId: sessionId)
            draft = ""
            return
        }
        // 先取出待发图片并立刻清空输入区 → 点击即时有反馈,不必干等编码。
        let images = stagedImages
        let sid = sessionId
        stagedImages = []
        draft = ""
        // 图片走 HTTP 数据通道,WS 控制通道只传 id(不再塞 base64)。全程后台:
        //   ① 编码:缩略图(回显用)+ 全尺寸 JPEG(上传用)—— 不卡主线程
        //   ② 即时回显缩略图(点完按钮马上看到气泡)
        //   ③ 逐张 HTTP 上传换回 id
        //   ④ 控制帧只带 id 发出
        Task.detached(priority: .userInitiated) { [relay] in
            var thumbs: [StagedImagePayload] = []   // 本地回显(小缩略图 base64)
            var fulls: [Data] = []                  // 上传用(1568px JPEG)
            for (i, img) in images.enumerated() {
                guard let full = img.resized(maxDim: 1568).jpegData(compressionQuality: 0.7) else { continue }
                let thumb = img.resized(maxDim: 600).jpegData(compressionQuality: 0.5) ?? full
                fulls.append(full)
                thumbs.append(StagedImagePayload(
                    data: thumb.base64EncodedString(), ext: "jpg",
                    name: "photo_\(i + 1).jpg", kind: "JPEG",
                    size: full.count >= 1_000_000
                        ? String(format: "%.1f MB", Double(full.count) / 1_000_000)
                        : "\(full.count / 1_000) KB"))
            }
            let localMsgId = await relay.beginImageEcho(thumbs: thumbs, text: text, sessionId: sid)
            // 并行上传(多图不再逐张排队),用下标回填保持原顺序。
            let uploaded: [Int: String] = await withTaskGroup(of: (Int, String?).self) { group in
                for (idx, full) in fulls.enumerated() {
                    group.addTask { (idx, try? await ImageAPI.upload(jpeg: full)) }
                }
                var byIdx: [Int: String] = [:]
                for await (idx, id) in group { if let id { byIdx[idx] = id } }
                return byIdx
            }
            var refs: [(id: String, ext: String)] = []
            for i in fulls.indices { if let id = uploaded[i] { refs.append((id: id, ext: "jpg")) } }
            await relay.sendImageRefs(refs: refs, text: text, sessionId: sid, localMsgId: localMsgId)
        }
    }
}

/// 「AI 正在思考」指示气泡:头像 + 三个呼吸跳动的圆点。
/// 会话状态 working 时挂在消息流末尾,让用户知道对面在干活。
struct TypingIndicatorRow: View {
    @State private var animate = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MessageAvatar(icon: "sparkles", colors: [Color(hex: 0x7C5CD6), Color(hex: 0xC061E0)])
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Theme.textSec)
                        .frame(width: 7, height: 7)
                        .scaleEffect(animate ? 1.2 : 0.7)
                        .opacity(animate ? 1 : 0.4)
                        .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.16), value: animate)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
            Spacer()
        }
        .onAppear { animate = true }
    }
}

private extension UIImage {
    /// 等比缩到最长边 maxDim(已小于则原样返回)。
    func resized(maxDim: CGFloat) -> UIImage {
        let m = max(size.width, size.height)
        guard m > maxDim else { return self }
        let scale = maxDim / m
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        // 关键:format.scale=1,让输出像素 = 点尺寸。否则 renderer 默认用屏幕 3x,
        // 「1568 点」会被渲成 4704 像素(约 3MB),缩放形同虚设、发图依旧又大又慢。
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: fmt).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

/// 系统相机(UIImagePickerController 封装)。
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onCapture(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
