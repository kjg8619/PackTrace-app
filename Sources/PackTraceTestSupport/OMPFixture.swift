import Foundation

/// Builders for OMP session JSONL lines.
///
/// The *shape* mirrors the installed OMP 18.2.8 log contract recorded in
/// docs/OMP_USAGE_SCHEMA.md: title record first, session header second, then
/// message records with `message.usage`. All values here are synthetic —
/// session ids, response ids, token counts and timestamps are invented, and no
/// prompt, response, thinking or tool content is present.
public enum OMPFixture {
    public static let session1 = "0199aaaa-0000-7000-8000-000000000001"
    public static let session2 = "0199bbbb-0000-7000-8000-000000000002"
    public static let provider = "commandcode"
    public static let model = "deepseek/deepseek-v4.1-flash"

    public static func responseID(_ n: Int) -> String {
        String(format: "gen_TEST%022d", n)
    }

    public static func title(_ text: String = "fixture session") -> String {
        #"{"type":"title","v":1,"title":"\#(text)","source":"auto","updatedAt":\#(timestamp(0)),"pad":""}"#
    }

    public static func header(sessionID: String = session1, version: Int = 3, cwd: String = "/fixture/project") -> String {
        """
        {"type":"session","id":"\(sessionID)","version":\(version),"timestamp":\(timestamp(0)),\
        "title":"fixture session","titleSource":"auto","cwd":"\(cwd)"}
        """
    }

    /// Assistant record with a complete usage block.
    public static func assistant(
        responseID: String,
        sessionID: String = session1,
        provider: String = provider,
        model: String = model,
        stopReason: String = "toolUse",
        input: Int = 1_200,
        output: Int = 300,
        cacheRead: Int = 40_000,
        cacheWrite: Int = 0,
        reasoning: Int? = nil,
        occurredAt: Int,
        completedAt: Int? = nil,
        totalTokens: Int? = nil
    ) -> String {
        var usage = """
        "input":\(input),"output":\(output),"cacheRead":\(cacheRead),"cacheWrite":\(cacheWrite)
        """
        if let reasoning {
            usage += ",\"reasoningTokens\":\(reasoning)"
        }
        let total = totalTokens ?? (input + output + cacheRead + cacheWrite)
        usage += ",\"totalTokens\":\(total),\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"total\":0}"
        let completed = completedAt.map { ",\"completedAt\":\($0)" } ?? ""
        return """
        {"type":"message","id":"rec_\(responseID)","parentId":"rec_parent","timestamp":\(occurredAt),\
        "message":{"role":"assistant","content":[],"api":"openai-completions","provider":"\(provider)",\
        "model":"\(model)","responseId":"\(responseID)","usage":{\(usage)},"stopReason":"\(stopReason)",\
        "timestamp":\(occurredAt)\(completed),"duration":1200,"ttft":300}}
        """
    }

    public static func toolResult(occurredAt: Int) -> String {
        """
        {"type":"message","id":"rec_tool_\(occurredAt)","parentId":"rec_parent","timestamp":\(occurredAt),\
        "message":{"role":"toolResult","toolCallId":"call_fixture","toolName":"read","content":[]}}
        """
    }

    public static func userMessage(occurredAt: Int) -> String {
        """
        {"type":"message","id":"rec_user_\(occurredAt)","parentId":"rec_parent","timestamp":\(occurredAt),\
        "message":{"role":"user","content":[{"type":"text","text":"fixture"}]}}
        """
    }

    public static func custom(_ customType: String = "tool_execution_start", occurredAt: Int = 1_790_000_000_000) -> String {
        """
        {"type":"custom","customType":"\(customType)","id":"rec_custom_\(occurredAt)","parentId":"rec_parent",\
        "timestamp":\(occurredAt),"data":{}}
        """
    }

    public static func modelChange() -> String {
        #"{"type":"model_change","id":"rec_model","parentId":"rec_parent","timestamp":1790000000000}"#
    }

    /// One complete session file: title, header, then the given assistant records.
    public static func sessionFile(
        sessionID: String = session1,
        version: Int = 3,
        assistants: [String]
    ) -> String {
        ([title(), header(sessionID: sessionID, version: version)] + assistants)
            .joined(separator: "\n") + "\n"
    }

    public static func timestamp(_ offsetSeconds: Int) -> Int {
        1_790_000_000_000 + offsetSeconds * 1_000
    }

    /// Writes a fixture tree under a temporary directory.
    public struct Tree {
        public var root: URL

        public init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("packtrace-omp-fixture", isDirectory: true)
                .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        @discardableResult
        public func write(_ contents: String, to relativePath: String) throws -> URL {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
            return url
        }

        public func append(_ contents: String, to relativePath: String) throws {
            let url = root.appendingPathComponent(relativePath)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(contents.utf8))
        }

        public func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
