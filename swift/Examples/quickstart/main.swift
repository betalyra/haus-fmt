// The quickstart: data typed by its schema, decoding, encoding and errors.
// The same steps as go/examples/quickstart and rust/examples/quickstart, on
// the same files. Run: swift run quickstart (from swift/).
import Foundation
import Haus

/// The shared example files.
let examples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("examples")

/// A comment of thread.schema.haus. `Comment { … }` is the one case of the
/// type `Comment`, so a struct holds it; its replies are comments again.
struct Comment: Codable {
    let author: String
    /// An `Instant`, as its text.
    let at: String
    let text: String
    var likes: Int
    let replies: [Comment]
}

func likes(_ c: Comment) -> Int { c.likes + c.replies.map(likes).reduce(0, +) }

func depth(_ c: Comment) -> Int { 1 + (c.replies.map(depth).max() ?? 0) }

let reply = #"Comment { author: "me", at: Instant("2026-11-16T09:00:00Z"), text: "+1", likes: 0, replies: [] }"#

do {
    let schema = try HausSchema(contentsOf: examples.appendingPathComponent("thread.schema.haus").path)
    let comment = try schema.type("Comment")

    // 1. The thread, as typed data: Root is a Comment, a struct; replies are [Comment].
    let text = try String(contentsOf: examples.appendingPathComponent("thread.haus"), encoding: .utf8)
    let thread = try schema.type("Root").decode(Comment.self, fromText: text)
    print("thread by \(thread.author): \(depth(thread)) levels, \(likes(thread)) likes")

    // 2. Decode haus text with the schema, change it, encode it back.
    var liked = try comment.decode(Comment.self, fromText: reply)
    liked.likes += 1
    print(try comment.stringify(liked, FormatOptions(layout: .compact)), terminator: "")

    // 3. A value that doesn't match the schema is an error that says where.
    do {
        _ = try comment.decode(
            Comment.self, fromText: reply.replacingOccurrences(of: "likes: 0", with: #"likes: "lots""#))
    } catch {
        print("error: \(error)")
    }
} catch {
    print(error)
    exit(1)
}
