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

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                navBar
                GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 14) {
                                sessionHeader
                                if let msgs = session?.messages, !msgs.isEmpty {
                                    ForEach(msgs) { msg in
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
                        .onChange(of: session?.messages.count ?? 0) { _, _ in
                            if session?.status == "working" {
                                withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
                            } else if let last = session?.messages.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                        .onChange(of: session?.status ?? "") { _, st in
                            if st == "working" {
                                withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
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
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
            }
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

    private var sessionHeader: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color(hex: 0x7C5CD6), Color(hex: 0xC061E0)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 52, height: 52)
                .overlay(Text(String((session?.title ?? "会").prefix(1)))
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 4) {
                Text(session?.title ?? "会话").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                let status = session?.status ?? "working"
                HStack(spacing: 6) {
                    Circle().fill(SessionStatusUI.color(status)).frame(width: 7, height: 7)
                    Text(SessionStatusUI.label(status))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(SessionStatusUI.color(status))
                    if let term = session?.terminal, !term.isEmpty, term != "?" {
                        Text("· \(term)").font(.system(size: 14)).foregroundStyle(Theme.textSec)
                    }
                }
                if let cwd = session?.cwd, !cwd.isEmpty, cwd != "?" {
                    HStack(spacing: 5) {
                        Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.textTer)
                        Text(shortMacPath(cwd)).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textSec).lineLimit(1).truncationMode(.head)
                    }
                }
            }
            Spacer()
        }
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
        // 缩放 / JPEG / base64 编码很重(原图越大越明显,HEIC 还要先解码),
        // 之前全在主线程同步跑、且要编完才回显气泡 → 点完按钮 UI 冻一下才动,
        // 就是「发图贼慢」的根源。挪到后台线程,编完再回主线程回显+发送。
        Task.detached(priority: .userInitiated) { [relay] in
            let payloads = images.enumerated().compactMap { i, img -> StagedImagePayload? in
                guard let jpeg = img.resized(maxDim: 1568).jpegData(compressionQuality: 0.7) else { return nil }
                return StagedImagePayload(
                    data: jpeg.base64EncodedString(), ext: "jpg",
                    name: "photo_\(i + 1).jpg", kind: "JPEG",
                    size: jpeg.count >= 1_000_000
                        ? String(format: "%.1f MB", Double(jpeg.count) / 1_000_000)
                        : "\(jpeg.count / 1_000) KB")
            }
            await MainActor.run {
                relay.sendImageInput(images: payloads, text: text, sessionId: sid)
            }
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
        return UIGraphicsImageRenderer(size: newSize).image { _ in
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
