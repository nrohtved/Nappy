import Foundation

/// Which build this is. The Public build (`-configuration Public`, compilation flag `PUBLIC`) is the one that
/// gets released: code that is only for development is wrapped in `#if !PUBLIC` and is not compiled into it.
/// The Dev build (Debug and Release configurations) keeps everything.
enum Stage {
    #if PUBLIC
    static let isPublic = true
    #else
    static let isPublic = false
    #endif

    static var name: String { isPublic ? "Public" : "Dev" }
}
