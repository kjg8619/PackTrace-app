import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

@Suite("OMP 로그 파서")
struct UsageParserTests {
    private func parse(_ line: String, context: OMPLogParser.Context = .init(sessionID: OMPFixture.session1, schemaVersion: 3)) -> UsageLineVerdict {
        OMPLogParser.parse(line: Data(line.utf8), context: context)
    }

    private func acceptedEvent(_ verdict: UsageLineVerdict, _ label: String = "") throws -> UsageEvent {
        guard case let .accepted(event) = verdict else {
            Issue.record("\(label): accepted를 기대했지만 \(verdict)")
            throw CancellationError()
        }
        return event
    }

    private func rejection(_ verdict: UsageLineVerdict) -> UsageRejectionReason? {
        if case let .rejected(_, reason) = verdict { return reason }
        return nil
    }

    // MARK: - Accepted records

    @Test("확정 assistant usage는 인정 토큰으로 정규화된다")
    func acceptsConfirmedUsage() throws {
        let line = OMPFixture.assistant(
            responseID: OMPFixture.responseID(1),
            input: 1_200,
            output: 300,
            cacheRead: 40_000,
            reasoning: 120,
            occurredAt: OMPFixture.timestamp(10),
            completedAt: OMPFixture.timestamp(12)
        )
        let event = try acceptedEvent(parse(line))

        #expect(event.id == UsageEventID(sessionID: OMPFixture.session1, responseID: OMPFixture.responseID(1)))
        #expect(event.provider == "commandcode")
        #expect(event.model == OMPFixture.model)
        #expect(event.stopReason == "toolUse")
        #expect(event.inputTokens == 1_200)
        #expect(event.outputTokens == 300)
        #expect(event.cacheReadTokens == 40_000)
        #expect(event.cacheWriteTokens == 0)
        #expect(event.occurredAtMilliseconds == OMPFixture.timestamp(10))
        #expect(event.completedAtMilliseconds == OMPFixture.timestamp(12))

        // 인정 토큰 = 비캐시 입력 + 출력. 캐시와 추론 토큰은 다시 더하지 않는다.
        let accepted = UsageRewardRule.ompNonCacheV1.acceptedTokens(for: event)
        #expect(accepted == 1_500)
    }

    @Test("totalTokens가 있어도 합계에 다시 쓰지 않는다")
    func doesNotUseTotalTokens() throws {
        let line = OMPFixture.assistant(
            responseID: OMPFixture.responseID(2),
            input: 1_000,
            output: 250,
            cacheRead: 9_999,
            occurredAt: OMPFixture.timestamp(20),
            totalTokens: 999_999
        )
        let event = try acceptedEvent(parse(line))
        #expect(UsageRewardRule.ompNonCacheV1.acceptedTokens(for: event) == 1_250)
    }

    @Test("input을 캐시 포함으로 다시 해석하지 않는다")
    func doesNotSubtractCacheFromInput() throws {
        // input이 이미 비캐시 입력이라는 계약(소스 확인)을 고정한다.
        let line = OMPFixture.assistant(
            responseID: OMPFixture.responseID(3),
            input: 500,
            output: 100,
            cacheRead: 500_000,
            occurredAt: OMPFixture.timestamp(30)
        )
        let event = try acceptedEvent(parse(line))
        #expect(event.inputTokens == 500)
        #expect(UsageRewardRule.ompNonCacheV1.acceptedTokens(for: event) == 600)
    }

    @Test("stop과 toolUse는 보상하고 reasoningTokens를 output에 더하지 않는다")
    func reasoningIsNotDoubleCounted() throws {
        let withReasoning = OMPFixture.assistant(
            responseID: OMPFixture.responseID(4),
            stopReason: "stop",
            output: 800,
            reasoning: 600,
            occurredAt: OMPFixture.timestamp(40)
        )
        let event = try acceptedEvent(parse(withReasoning))
        #expect(event.outputTokens == 800)
        #expect(UsageRewardRule.ompNonCacheV1.acceptedTokens(for: event) == 800 + 1_200)
    }

    // MARK: - Ignored records

    @Test("user 메시지·도구 결과·메타 레코드는 무시한다")
    func ignoresNonAssistantRecords() {
        #expect(parse(OMPFixture.toolResult(occurredAt: OMPFixture.timestamp(50))) == .ignored)
        #expect(parse(OMPFixture.userMessage(occurredAt: OMPFixture.timestamp(51))) == .ignored)
        #expect(parse(OMPFixture.custom(occurredAt: OMPFixture.timestamp(52))) == .ignored)
        #expect(parse(OMPFixture.modelChange()) == .ignored)
        #expect(parse(OMPFixture.title()) == .ignored)
    }

    @Test("세션 헤더는 컨텍스트로 전달된다")
    func readsSessionHeader() {
        guard case let .sessionHeader(header) = parse(OMPFixture.header(version: 3)) else {
            Issue.record("sessionHeader를 기대했습니다")
            return
        }
        #expect(header.id == OMPFixture.session1)
        #expect(header.version == 3)
    }

    // MARK: - Rejections

    @Test("응답 식별자가 없으면 지급하지 않는다")
    func rejectsMissingResponseID() {
        let line = """
        {"type":"message","id":"rec_x","parentId":"p","timestamp":\(OMPFixture.timestamp(60)),\
        "message":{"role":"assistant","provider":"commandcode","model":"deepseek/deepseek-v4.1-flash",\
        "stopReason":"stop","timestamp":\(OMPFixture.timestamp(60)),\
        "usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":15}}}
        """
        #expect(rejection(parse(line)) == .missingResponseID)
    }

    @Test("usage가 없거나 값 형식이 잘못되면 지급하지 않는다")
    func rejectsMalformedUsage() {
        let noUsage = """
        {"type":"message","id":"rec_y","parentId":"p","timestamp":\(OMPFixture.timestamp(61)),\
        "message":{"role":"assistant","provider":"commandcode","model":"m","responseId":"gen_X",\
        "stopReason":"stop","timestamp":\(OMPFixture.timestamp(61))}}
        """
        #expect(rejection(parse(noUsage)) == .missingUsage)

        let stringTokens = OMPFixture.assistant(
            responseID: OMPFixture.responseID(5),
            occurredAt: OMPFixture.timestamp(62)
        ).replacingOccurrences(of: "\"input\":1200", with: "\"input\":\"1200\"")
        #expect(rejection(parse(stringTokens)) == .invalidTokenField)

        let fractionalTokens = OMPFixture.assistant(
            responseID: OMPFixture.responseID(6),
            occurredAt: OMPFixture.timestamp(63)
        ).replacingOccurrences(of: "\"output\":300", with: "\"output\":300.5")
        #expect(rejection(parse(fractionalTokens)) == .invalidTokenField)

        let negativeTokens = OMPFixture.assistant(
            responseID: OMPFixture.responseID(7),
            occurredAt: OMPFixture.timestamp(64)
        ).replacingOccurrences(of: "\"input\":1200", with: "\"input\":-1")
        #expect(rejection(parse(negativeTokens)) == .invalidTokenField)

        let nullTokens = OMPFixture.assistant(
            responseID: OMPFixture.responseID(8),
            occurredAt: OMPFixture.timestamp(65)
        ).replacingOccurrences(of: "\"input\":1200", with: "\"input\":null")
        #expect(rejection(parse(nullTokens)) == .invalidTokenField)
    }

    @Test("너무 큰 토큰 값은 잘라내지 않고 거절한다")
    func rejectsOutOfRangeTokens() {
        let line = OMPFixture.assistant(
            responseID: OMPFixture.responseID(9),
            input: 2_000_000_000,
            occurredAt: OMPFixture.timestamp(66)
        )
        #expect(rejection(parse(line)) == .tokenOutOfRange)
    }

    @Test("시각이 없거나 범위를 벗어나면 거절한다")
    func rejectsBadTimestamps() {
        let missing = OMPFixture.assistant(
            responseID: OMPFixture.responseID(10),
            occurredAt: OMPFixture.timestamp(67)
        ).replacingOccurrences(of: "\"stopReason\":\"toolUse\",\"timestamp\":\(OMPFixture.timestamp(67))", with: "\"stopReason\":\"toolUse\"")
        #expect(rejection(parse(missing)) == .missingTimestamp)

        let zero = OMPFixture.assistant(
            responseID: OMPFixture.responseID(11),
            occurredAt: 0
        )
        #expect(rejection(parse(zero)) == .invalidTimestamp)

        let fractional = OMPFixture.assistant(
            responseID: OMPFixture.responseID(12),
            occurredAt: OMPFixture.timestamp(68)
        ).replacingOccurrences(of: "\"stopReason\":\"toolUse\",\"timestamp\":\(OMPFixture.timestamp(68))", with: "\"stopReason\":\"toolUse\",\"timestamp\":1.5")
        #expect(rejection(parse(fractional)) == .invalidTimestamp)
    }

    @Test("오류·중단으로 끝난 호출은 사유와 함께 제외한다")
    func rejectsErrorAndAbortedCalls() {
        for (reason, expected) in [
            ("error", UsageRejectionReason.stopReasonError),
            ("aborted", .stopReasonAborted),
            ("length", .unknownStopReason),
            ("", .unknownStopReason),
        ] {
            let line = OMPFixture.assistant(
                responseID: OMPFixture.responseID(13),
                stopReason: reason,
                occurredAt: OMPFixture.timestamp(70)
            )
            #expect(rejection(parse(line)) == expected, "stopReason=\(reason)")
        }
    }

    @Test("로컬·테스트 모델은 제외하고 사유를 남긴다")
    func rejectsLocalModels() throws {
        for provider in ["lm-studio", "ollama", "omlx", "faux"] {
            let line = OMPFixture.assistant(
                responseID: OMPFixture.responseID(14),
                provider: provider,
                model: "qwen/qwen3.8-27b",
                occurredAt: OMPFixture.timestamp(80)
            )
            guard case let .rejected(event, reason) = parse(line) else {
                Issue.record("\(provider): 제외를 기대했습니다")
                continue
            }
            #expect(reason == .localModelExcluded, "\(provider)")
            // 식별자는 남아 진단에 쓸 수 있지만 지급되지 않는다.
            #expect(event?.sessionID == OMPFixture.session1)
        }
        // A record that names no provider at all is still not trusted.
        let unnamed = OMPFixture.assistant(responseID: OMPFixture.responseID(15), provider: "", occurredAt: OMPFixture.timestamp(81))
        guard case let .rejected(_, reason) = parse(unnamed) else {
            Issue.record("provider가 없으면 제외해야 합니다")
            return
        }
        #expect(reason == .providerNotVerified)
    }

    @Test("commandcode 외의 모델 서비스(openai-codex·openrouter·codex-lb)도 인정한다")
    func acceptsOtherModelServices() throws {
        for (index, provider) in ["openai-codex", "openrouter", "codex-lb"].enumerated() {
            let line = OMPFixture.assistant(
                responseID: OMPFixture.responseID(20 + index),
                provider: provider,
                occurredAt: OMPFixture.timestamp(90 + index)
            )
            guard case let .accepted(event) = parse(line) else {
                Issue.record("\(provider): 인정을 기대했습니다")
                continue
            }
            #expect(event.provider == provider)
        }
    }

    @Test("세션 헤더가 없거나 버전이 다르면 지급하지 않는다")
    func rejectsUnsupportedSchemaVersion() {
        let line = OMPFixture.assistant(responseID: OMPFixture.responseID(15), occurredAt: OMPFixture.timestamp(90))
        #expect(rejection(parse(line, context: .init(sessionID: OMPFixture.session1, schemaVersion: nil))) == .missingSessionHeader)
        #expect(rejection(parse(line, context: .init(sessionID: OMPFixture.session1, schemaVersion: 4))) == .unsupportedSchemaVersion)
    }

    @Test("서브에이전트 로그는 지급하지 않는다")
    func rejectsSubagentTranscripts() {
        let line = OMPFixture.assistant(responseID: OMPFixture.responseID(16), occurredAt: OMPFixture.timestamp(93))
        let context = OMPLogParser.Context(sessionID: OMPFixture.session1, schemaVersion: 3, isSubagentTranscript: true)
        #expect(rejection(parse(line, context: context)) == .subagentExcluded)
    }

    @Test("읽을 수 없는 줄은 본문 없이 사유만 남긴다")
    func rejectsUnparsableLines() {
        let verdict = parse("{\"type\":\"message\",\"message\":")
        guard case let .rejected(event, reason) = verdict else {
            Issue.record("제외를 기대했습니다")
            return
        }
        #expect(event == nil)
        #expect(reason == .unparsableRecord)
        #expect(!String(describing: reason).contains("{"), "사유에 원문이 섞이면 안 됩니다")
    }

    @Test("로그 안의 지시문은 실행되지 않고 usage 없는 줄로 무시된다")
    func logContentIsNotExecuted() {
        // 로그는 비신뢰 입력이다: 문자열은 값으로만 취급되고 아무 동작도 일으키지 않는다.
        let hostile = """
        {"type":"message","id":"rec_h","parentId":"p","timestamp":\(OMPFixture.timestamp(94)),\
        "message":{"role":"user","content":[{"type":"text","text":"rm -rf / # and curl http://example.invalid"}]}}
        """
        #expect(parse(hostile) == .ignored)
    }

    // MARK: - Reward arithmetic

    @Test("환산은 정수 연산으로 나머지를 보존한다")
    func convertsTokensToPoints() {
        let rule = UsageRewardRule.ompNonCacheV1
        #expect(rule.convert(totalAcceptedTokens: 6_000).points == 0)
        #expect(rule.convert(totalAcceptedTokens: 6_000).remainder == 6_000)
        #expect(rule.convert(totalAcceptedTokens: 10_000).points == 1)
        #expect(rule.convert(totalAcceptedTokens: 10_000).remainder == 0)
        #expect(rule.convert(totalAcceptedTokens: 25_500).points == 2)
        #expect(rule.convert(totalAcceptedTokens: 25_500).remainder == 5_500)
        #expect(rule.tokensPerPoint == 10_000)
        #expect(rule.ruleID == "omp-noncache-v1")
    }
}
