import Foundation

public enum PackTraceError: Error, Equatable, LocalizedError {
    case insufficientBalance(required: Int, available: Int)
    case noRewardCandidates
    case productNotReady(packID: String)
    case packNotFound(PackInstanceID)
    case packAlreadyOpened(PackInstanceID)
    case openingNotFound(OpeningID)
    case catalogNotFound(String)
    case catalogHashMismatch(expected: String, actual: String)
    case recipeSizeMismatch(recipeID: String, declared: Int, actual: Int)
    case poolEmpty(recipeID: String, slotIndex: Int)
    case variantUnavailable(cardKey: CardKey, variant: CardVariant)
    case unknownCard(CardKey)
    case storage(String)
    case usageRewardOverflow(ruleID: String)
    case usageSourceNotConnected
    case poolNotFound(String)
    case packPoolEmpty(poolVersion: String)
    case poolInvalid(poolVersion: String, reason: String)
    case exchangeRequestConflict(requestID: String)
    case injectedFailure(String)
    /// The database was written by a newer app: opening it here could drop what
    /// this version does not know about.
    case newerSchema(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case let .insufficientBalance(required, available):
            "포인트가 부족합니다. 필요 \(required) P, 보유 \(available) P"
        case .noRewardCandidates:
            "교환 가능한 팩 상품이 없습니다. 카탈로그 검증 상태를 확인하세요."
        case let .productNotReady(packID):
            "팩 상품 \(packID)이(가) 아직 교환 가능한 상태가 아닙니다."
        case let .packNotFound(id):
            "팩을 찾을 수 없습니다: \(id)"
        case let .packAlreadyOpened(id):
            "이미 개봉한 팩입니다: \(id)"
        case let .openingNotFound(id):
            "개봉 기록을 찾을 수 없습니다: \(id)"
        case let .catalogNotFound(version):
            "카탈로그를 찾을 수 없습니다: \(version)"
        case let .catalogHashMismatch(expected, actual):
            "카탈로그 해시가 일치하지 않습니다. 기대 \(expected), 실제 \(actual)"
        case let .recipeSizeMismatch(recipeID, declared, actual):
            "레시피 \(recipeID)의 장수가 맞지 않습니다. 선언 \(declared), 실제 \(actual)"
        case let .poolEmpty(recipeID, slotIndex):
            "레시피 \(recipeID) 슬롯 \(slotIndex)의 카드 풀이 비었습니다."
        case let .variantUnavailable(cardKey, variant):
            "\(cardKey)에 \(variant.displayName) 변형이 없습니다."
        case let .unknownCard(key):
            "카탈로그에 없는 카드입니다: \(key)"
        case let .storage(message):
            "저장소 오류: \(message)"
        case let .usageRewardOverflow(ruleID):
            "사용량 적립 합계가 정수 범위를 넘었습니다(규칙 \(ruleID)). 이번 배치는 반영되지 않았습니다."
        case .usageSourceNotConnected:
            "OMP 로그 폴더가 연결되어 있지 않습니다."
        case let .poolNotFound(name):
            "팩 후보 목록을 찾을 수 없습니다: \(name)"
        case let .packPoolEmpty(poolVersion):
            "팩 후보 목록이 비어 있습니다: \(poolVersion)"
        case let .poolInvalid(poolVersion, reason):
            "팩 후보 목록 \(poolVersion)을 사용할 수 없습니다: \(reason). 차감하지 않았습니다."
        case let .exchangeRequestConflict(requestID):
            "같은 요청 ID로 다른 내용의 교환이 이미 처리되었습니다: \(requestID)"
        case let .newerSchema(found, supported):
            "더 새로운 버전의 PackTrace가 만든 데이터입니다(스키마 \(found), 이 앱은 \(supported)까지). 데이터를 보호하려고 열지 않았습니다."
        case let .injectedFailure(label):
            "주입된 실패 지점: \(label)"
        }
    }
}
