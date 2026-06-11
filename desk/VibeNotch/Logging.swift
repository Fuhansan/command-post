import Foundation

@inline(__always)
func vlog(_ msg: String) {
    let line = "[VibeNotch] \(msg)\n"
    FileHandle.standardError.write(Data(line.utf8))
}
