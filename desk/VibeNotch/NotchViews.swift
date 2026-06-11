import MarkdownUI
import SwiftUI

struct NotchCompactDot: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }
}

/// Two-dot compact summary that reads a SessionStore and reflects:
/// - leading: most-urgent state across all sessions
/// - trailing: count badge (or static green if there are sessions)
struct NotchCompactSummary: View {
    @ObservedObject var store: SessionStore
    let position: Position

    enum Position { case leading, trailing }

    var body: some View {
        Group {
            switch position {
            case .leading:
                Circle()
                    .fill(aggregateColor)
                    .frame(width: 6, height: 6)
            case .trailing:
                if store.sessions.isEmpty {
                    Circle()
                        .stroke(DesignTokens.textTertiary, lineWidth: 1)
                        .frame(width: 6, height: 6)
                } else {
                    Text("\(store.sessions.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DesignTokens.textPrimary)
                }
            }
        }
        .animation(DesignTokens.stateTween, value: aggregateColor)
    }

    private var aggregateColor: Color {
        // Priority: waiting (orange) > working (blue) > done (green) > idle (gray)
        var hasWorking = false, hasDone = false
        for s in store.sessions {
            switch s.state {
            case .waiting: return DesignTokens.stateWaiting
            case .working: hasWorking = true
            case .done:    hasDone = true
            case .idle:    break
            }
        }
        if hasWorking { return DesignTokens.stateWorking }
        if hasDone    { return DesignTokens.stateDone }
        return DesignTokens.stateIdle
    }
}

/// Per-row state indicator. Working state pulses; waiting/done are static.
struct StateDot: View {
    let state: SessionState
    @State private var pulseOn = false

    var body: some View {
        ZStack {
            if isWorking {
                Circle()
                    .fill(color)
                    .frame(width: DesignTokens.stateDot, height: DesignTokens.stateDot)
                    .scaleEffect(pulseOn ? 3.0 : 1.0)
                    .opacity(pulseOn ? 0.0 : 0.7)
            }
            Circle()
                .fill(color)
                .frame(width: DesignTokens.stateDot, height: DesignTokens.stateDot)
        }
        .frame(width: DesignTokens.stateDot * 3.0, height: DesignTokens.stateDot * 3.0)
        .onAppear {
            if isWorking {
                withAnimation(DesignTokens.pulse) { pulseOn = true }
            }
        }
        .animation(DesignTokens.stateTween, value: color)
    }

    private var color: Color {
        switch state {
        case .idle:       return DesignTokens.stateIdle
        case .working(_, _): return DesignTokens.stateWorking
        case .waiting(_):    return DesignTokens.stateWaiting
        case .done(_, _):    return DesignTokens.stateDone
        }
    }

    private var isWorking: Bool {
        if case .working = state { return true }
        return false
    }
}

struct NotchExpandedView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var pending: PendingDecisionStore
    var onDecide: (String, PermissionDecision) -> Void
    var onJump: (String) -> Void
    var onOpenFile: (String, String) -> Void
    @State private var expandedID: String? = nil
    @State private var lastClickAt: Date? = nil
    @State private var lastClickedID: String? = nil
    private static let doubleClickWindow: TimeInterval = 0.32

    private func toggleExpanded(_ sid: String) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
            expandedID = (expandedID == sid) ? nil : sid
        }
    }

    /// Single click: toggle expand IMMEDIATELY (snappy).
    /// Second click within 320ms on same row: also fire jump.
    private func handleRowClick(sid: String, jump: () -> Void) {
        let now = Date()
        if lastClickedID == sid,
           let last = lastClickAt,
           now.timeIntervalSince(last) < Self.doubleClickWindow {
            lastClickAt = nil
            lastClickedID = nil
            jump()
        } else {
            lastClickAt = now
            lastClickedID = sid
            toggleExpanded(sid)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if store.sessions.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    sessionList
                }
                .frame(maxHeight: 400)
            }
        }
        .padding(.horizontal, DesignTokens.spaceMD)
        .padding(.top, DesignTokens.spaceSM)
        .padding(.bottom, DesignTokens.spaceSM)
        .frame(width: DesignTokens.panelWidth, alignment: .leading)
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.sessions.enumerated()), id: \.element.id) { idx, entry in
                        if idx > 0 {
                            Divider()
                                .background(DesignTokens.borderDivider)
                                .padding(.leading, 22)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            SessionRow(
                                entry: entry,
                                onJumpTerminal: { onJump(entry.id) }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                handleRowClick(sid: entry.id) { onJump(entry.id) }
                            }
                            if expandedID == entry.id {
                                DetailCard(
                                    entry: entry,
                                    onOpenFile: { path in onOpenFile(entry.id, path) }
                                )
                                    .transition(
                                        .asymmetric(
                                            insertion: .scale(scale: 0.92, anchor: .top)
                                                .combined(with: .opacity),
                                            removal: .scale(scale: 0.96, anchor: .top)
                                                .combined(with: .opacity)
                                        )
                                    )
                            }
                            if pending.pendingIDs.contains(entry.id) {
                                PermissionCard(
                                    entry: entry,
                                    onAllow: { onDecide(entry.id, .allow) },
                                    onDeny: { onDecide(entry.id, .deny) }
                                )
                            }
                        }
                    }
        }
    }

    private var header: some View {
        HStack(spacing: DesignTokens.spaceXS + 2) {
            Text("VibeNotch")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignTokens.textPrimary)
                .tracking(0.2)
            Spacer()
            if !store.sessions.isEmpty {
                Text("\(store.sessions.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DesignTokens.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.06))
                    )
            }
        }
        .padding(.horizontal, DesignTokens.spaceSM)
        .padding(.bottom, DesignTokens.spaceXS + 2)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(DesignTokens.textTertiary)
            Text("No active sessions")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textSecondary)
            Text("VibeNotch wakes up when claude does")
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.spaceLG)
    }
}

struct SessionRow: View {
    let entry: SessionEntry
    var onJumpTerminal: () -> Void = {}
    @State private var isHovered = false
    @State private var badgeHovered = false

    /// Distance from row's left edge to where the prompt text begins.
    /// Reused as line-2 indent so the reply aligns under the prompt text.
    private static let textIndent: CGFloat = DesignTokens.stateDot * 3 + DesignTokens.spaceSM

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: DesignTokens.spaceSM) {
                StateDot(state: entry.state)
                Text(primaryText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if entry.terminal != .unknown {
                    Button(action: onJumpTerminal) {
                        HStack(spacing: 3) {
                            Image(systemName: entry.terminal.sfSymbol)
                                .font(.system(size: 9, weight: .medium))
                            Text(entry.terminal.displayName)
                                .font(.system(size: 9, weight: .medium))
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 8, weight: .medium))
                                .opacity(badgeHovered ? 0.9 : 0.4)
                        }
                        .foregroundStyle(.white.opacity(badgeHovered ? 0.95 : 0.75))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(
                                Color.white.opacity(badgeHovered ? 0.18 : 0.10)
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { badgeHovered = $0 }
                    .help("Jump to terminal")
                }
                Text(elapsedText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            if let secondary = secondaryText {
                Text(secondary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(secondaryLineLimit)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Self.textIndent)
            }
        }
        .padding(.horizontal, DesignTokens.spaceSM)
        .padding(.vertical, DesignTokens.spaceXS + 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.white.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    private var stateColor: Color {
        switch entry.state {
        case .idle:
            return Color(hex: 0x8E8E93)
        case .working(_, _):
            return Color(hex: 0x0A84FF)
        case .waiting(_):
            return Color(hex: 0xFF9F0A)
        case .done(_, _):
            return Color(hex: 0x30D158)
        }
    }

    private var primaryText: String {
        let raw: String? = {
            switch entry.state {
            case .idle, .working, .done:
                return entry.promptSummary
            case .waiting(let msg):
                return entry.promptSummary ?? msg
            }
        }()
        if let r = raw, !r.isEmpty { return Self.flatten(r) }
        switch entry.state {
        case .idle: return "idle"
        case .working: return "working…"
        case .waiting(let msg): return msg
        case .done: return "Done"
        }
    }

    private var secondaryText: String? {
        switch entry.state {
        case .idle:
            return nil
        case .working:
            if let r = entry.lastReplyBlock?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty {
                return Self.flatten(r)
            }
            return entry.toolDetail
        case .waiting(let msg):
            return msg
        case .done:
            return entry.lastReplyBlock.map(Self.flatten)
        }
    }

    /// Replaces newlines with spaces and collapses runs of whitespace so
    /// SwiftUI can fill the available width and ellipsis-truncate cleanly.
    /// The original multiline text is preserved on the entry for DetailCard.
    private static func flatten(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed
            .split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    /// `done` rows can wrap the reply to 2 lines so users see more context.
    /// All other rows keep a tight 1-line subtitle.
    private var secondaryLineLimit: Int {
        if case .done = entry.state { return 2 }
        return 1
    }

    private var elapsedText: String {
        let start: Date = {
            switch entry.state {
            case .working(_, let s): return s
            case .done(_, let at): return at
            default: return entry.startedAt
            }
        }()
        let secs = max(0, Int(Date().timeIntervalSince(start)))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h"
    }
}

/// Conversation detail panel — full prompt + full reply in a chat layout.
/// Triggered by single-clicking a session row; collapses on next click.
struct DetailCard: View {
    let entry: SessionEntry
    var onOpenFile: (String) -> Void = { _ in }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                if let prompt = nonEmpty(entry.promptSummary) {
                    youBlock(prompt: prompt)
                }
                if !entry.turnSteps.isEmpty {
                    claudeTimeline
                }
                if nonEmpty(entry.promptSummary) == nil && entry.turnSteps.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.5)
                        Text("Waiting for transcript…")
                            .font(.system(size: 10))
                            .foregroundStyle(DesignTokens.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                }
            }
            .padding(14)
        }
        .frame(maxHeight: 300)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, DesignTokens.spaceSM)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private static let userColor = Color(hex: 0x0A84FF)
    private static let assistantColor = Color(hex: 0x30D158)

    private func youBlock(prompt: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            avatar(icon: "person.fill", color: Self.userColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("You")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Self.userColor)
                    .tracking(0.3)
                RichText(raw: prompt)
            }
        }
    }

    private func avatar(icon: String, color: Color) -> some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.18))
                .overlay(
                    Circle().stroke(color.opacity(0.4), lineWidth: 0.6)
                )
                .frame(width: 22, height: 22)
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
        }
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private var claudeTimeline: some View {
        HStack(alignment: .top, spacing: 9) {
            avatar(icon: "sparkle", color: Self.assistantColor)
            VStack(alignment: .leading, spacing: 7) {
                Text("Claude")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Self.assistantColor)
                    .tracking(0.3)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(entry.turnSteps.enumerated()), id: \.offset) { _, step in
                        TimelineRow(step: step, onOpenFile: onOpenFile)
                    }
                }
            }
        }
    }
}

/// One row of the Claude timeline: either a text block (with ⭕ marker) or
/// a tool-use chip.
struct TimelineRow: View {
    let step: TurnStep
    var onOpenFile: (String) -> Void = { _ in }

    var body: some View {
        switch step {
        case .text(let s):
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(Color(hex: 0x30D158))
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                RichText(raw: s)
            }
        case .tool(let name, let input):
            HStack(alignment: .top, spacing: 8) {
                Color.clear.frame(width: 6, height: 6).padding(.top, 6)
                let tap: (() -> Void)? = {
                    guard let path = Self.openableFilePath(name: name, input: input) else { return nil }
                    return { onOpenFile(path) }
                }()
                ToolMilestone(name: name, input: input, onTap: tap)
            }
        }
    }

    /// Returns the file path to open if this tool chip refers to a file.
    static func openableFilePath(name: String, input: String?) -> String? {
        guard let input, !input.isEmpty else { return nil }
        switch name {
        case "Edit", "Write", "Read", "NotebookEdit":
            return input
        default:
            return nil
        }
    }
}

/// One message bubble in the chat layout (user or assistant).
struct MessageBlock: View {
    enum Role {
        case user
        case assistant

        var label: String { self == .user ? "You" : "Claude" }
        var icon: String { self == .user ? "person.fill" : "sparkle" }
        var color: Color {
            self == .user ? Color(hex: 0x0A84FF) : Color(hex: 0x30D158)
        }
    }
    let role: Role
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: role.icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(role.label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(role.color)

            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
        }
    }
}

/// Inline timeline marker for a tool invocation. Each tool category gets a
/// distinct accent color so the visual rhythm of the timeline carries info
/// at a glance: orange-Bash, purple-Edit, cyan-Read, yellow-Grep, green-Web.
struct ToolMilestone: View {
    let name: String
    let input: String?
    var onTap: (() -> Void)? = nil
    @State private var hovered = false

    private var chip: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 12, alignment: .center)
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.2)
            if let input, !input.isEmpty {
                Text(input)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if onTap != nil {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(hovered ? 0.9 : 0.55)
            }
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(accent.opacity(hovered ? 0.22 : 0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(accent.opacity(hovered ? 0.55 : 0.30), lineWidth: 0.5)
                )
        )
    }

    var body: some View {
        if let onTap {
            Button(action: onTap) { chip }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .help("Open file")
        } else {
            chip
        }
    }

    private var accent: Color {
        switch name {
        case "Bash":                          return Color(hex: 0xFF9F0A) // orange — execution
        case "Edit", "Write", "NotebookEdit": return Color(hex: 0xBF5AF2) // purple — modify
        case "Read":                          return Color(hex: 0x64D2FF) // cyan — read
        case "Grep", "Glob":                  return Color(hex: 0xFFD60A) // yellow — search
        case "WebFetch", "WebSearch":         return Color(hex: 0x32D74B) // green — web
        case "Task":                          return Color(hex: 0xFF453A) // red — sub-agent
        case "TodoWrite":                     return Color(hex: 0x0A84FF) // blue — tasks
        default:                              return Color.white.opacity(0.6)
        }
    }

    private var iconName: String {
        switch name {
        case "Bash":      return "terminal.fill"
        case "Edit", "Write", "NotebookEdit": return "square.and.pencil"
        case "Read":      return "doc.text.fill"
        case "Grep":      return "magnifyingglass"
        case "Glob":      return "doc.viewfinder.fill"
        case "WebFetch":  return "globe"
        case "WebSearch": return "globe.badge.chevron.backward"
        case "Task":      return "person.crop.circle.badge.questionmark"
        case "TodoWrite": return "checklist"
        default:          return "wrench.and.screwdriver"
        }
    }
}

/// Full markdown renderer powered by MarkdownUI: headings, lists, block
/// quotes, fenced code blocks (with language label), inline code, bold,
/// italic, strikethrough, links, and basic tables. Themed for the dark notch.
struct RichText: View {
    let raw: String

    var body: some View {
        Markdown(raw)
            .textSelection(.enabled)
            .markdownTheme(.vibeNotch)
    }
}

private extension Theme {
    static let vibeNotch = Theme()
        .text {
            ForegroundColor(.white.opacity(0.92))
            FontSize(11)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(10.5)
            ForegroundColor(Color(hex: 0xFFD60A))
            BackgroundColor(.white.opacity(0.10))
        }
        .strong { FontWeight(.semibold) }
        .emphasis { FontStyle(.italic) }
        .link { ForegroundColor(Color(hex: 0x0A84FF)) }
        .heading1 { config in
            VStack(alignment: .leading, spacing: 0) {
                config.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(13)
                        ForegroundColor(.white.opacity(0.95))
                    }
            }
            .padding(.top, 2)
        }
        .heading2 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(12)
                    ForegroundColor(.white.opacity(0.95))
                }
        }
        .heading3 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(11)
                    ForegroundColor(.white.opacity(0.92))
                }
        }
        .blockquote { config in
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.white.opacity(0.20))
                    .frame(width: 2)
                config.label.markdownTextStyle {
                    ForegroundColor(.white.opacity(0.7))
                    FontStyle(.italic)
                }
            }
        }
        .codeBlock { config in
            VStack(alignment: .leading, spacing: 3) {
                if let lang = config.language, !lang.isEmpty {
                    Text(lang)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .tracking(0.4)
                }
                config.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(10)
                        ForegroundColor(.white.opacity(0.88))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
            )
        }
        .listItem { config in
            config.label.markdownMargin(top: 1, bottom: 1)
        }
}

struct PermissionCard: View {
    let entry: SessionEntry
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let detail = entry.toolDetail {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(6)
            }
            HStack(spacing: 6) {
                Button(action: onDeny) {
                    Text("Deny")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color(hex: 0xFF453A).opacity(0.18))
                        .foregroundStyle(Color(hex: 0xFF453A))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button(action: onAllow) {
                    Text("Allow")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color(hex: 0x0A84FF))
                        .foregroundStyle(.white)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 14)   // align with text after the state dot
        .padding(.top, 4)
        .padding(.bottom, 4)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
