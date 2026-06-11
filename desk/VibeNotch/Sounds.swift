import AppKit

/// Plays system sounds in response to session state transitions.
/// Uses macOS bundled NSSound names (no asset shipping required).
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    @Published var muted = false

    private init() {}

    func playForTransition(to state: SessionState) {
        guard !muted else { return }
        let name: String? = {
            switch state {
            case .done:    return "Glass"     // light "ting" — task complete
            case .waiting: return "Funk"      // "uh-oh" — needs attention
            case .working: return nil
            case .idle:    return nil
            }
        }()
        guard let name, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.stop()
        sound.play()
    }
}
