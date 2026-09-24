import Foundation
import Testing

@testable import PackTraceCore

@Suite("툴체인 스모크")
struct ToolchainSmokeTests {
    @Test("Swift Testing을 사용할 수 있다")
    func swiftTestingAvailable() {
        #expect(PackEconomy.v1.packCostPoints == 100)
    }
}
