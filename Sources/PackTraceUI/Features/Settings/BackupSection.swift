import PackTraceCore
import SwiftUI

/// Backup and restore for the active profile.
///
/// A backup is a directory holding the database, the manifest and the catalogue
/// snapshots the stored packs are pinned to. Card images and the raw tool logs are
/// never copied: they stay where they are and are never uploaded.
struct BackupSection: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(
                    title: "데이터 백업·복원",
                    subtitle: "현재 프로필(\(environment.profile.displayName))의 지갑·팩·카드·개봉 기록·사용량 누적을 담습니다."
                )

                HStack(spacing: 8) {
                    Button("지금 백업") {
                        Task { await environment.createBackup() }
                    }
                    .controlSize(.small)
                    .disabled(environment.isBackingUp || environment.isRestoring)

                    if environment.isBackingUp {
                        ProgressView().controlSize(.small)
                        Text("백업 생성 중…")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.inkMuted)
                    }
                    if environment.isRestoring {
                        ProgressView().controlSize(.small)
                        Text("복원 중… 수집을 멈추고 검사한 뒤 교체합니다.")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.inkMuted)
                    }
                    Spacer(minLength: 0)
                }

                if let result = environment.lastBackupResult {
                    Text(result)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let notice = environment.lastRestoreNotice {
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.accentWarm)
                }

                Text("· 담는 것: SQLite 스냅샷(SQLite online backup API), manifest, 팩이 고정된 카탈로그 스냅샷")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
                Text("· 담지 않는 것: 카드 이미지, AI 도구의 로그·DB 원본, 인증정보. 백업 파일은 이 Mac 안에만 생기고 자동 업로드하지 않습니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)

                Divider().overlay(Palette.hairline)

                if environment.backups.isEmpty {
                    Text("아직 이 프로필의 백업이 없습니다.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.inkMuted)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(environment.backups) { backup in
                            backupRow(backup)
                        }
                    }
                }

                Text("복원은 현재 데이터를 지우고 백업 시점으로 되돌립니다. 복원한 뒤에는 연결했던 AI 도구를 모두 다시 연결해야 하며, 다시 연결한 도구부터 수집이 재개됩니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { environment.refreshBackups() }
        .confirmationDialog(
            environment.restoreConfirmation.map { "‘\($0.displayName)’ 시점으로 복원할까요?" } ?? "복원할까요?",
            isPresented: Binding(
                get: { environment.restoreConfirmation != nil },
                set: { if !$0 { environment.restoreConfirmation = nil } }
            ),
            titleVisibility: .visible,
            presenting: environment.restoreConfirmation
        ) { backup in
            Button("복원", role: .destructive) {
                environment.restoreConfirmation = nil
                Task { await environment.restore(from: backup) }
            }
            Button("취소", role: .cancel) { environment.restoreConfirmation = nil }
        } message: { backup in
            Text(
                """
                잔액 \(backup.manifest.counts.balancePoints) P · 미개봉 \(backup.manifest.counts.sealedPacks) · \
                개봉 \(backup.manifest.counts.openedPacks) · 카드 \(backup.manifest.counts.ownedCards)
                지금 있는 팩·카드·개봉 기록·사용량 누적은 이 시점으로 대체됩니다. \
                복원 직후에는 수집이 멈추고, 다시 연결한 뒤 새로 발생한 사용량부터 적립됩니다.
                """
            )
        }
    }

    private func backupRow(_ backup: AppEnvironment.BackupSummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(backup.displayName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                Text(backup.detailLine)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
                Text(
                    "만든 시각 \(backup.createdAtLabel) · 스키마 v\(backup.manifest.appSchemaVersion) · 형식 v\(backup.manifest.formatVersion)"
                )
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
            }
            Spacer(minLength: 0)
            Button("복원") {
                environment.restoreConfirmation = backup
            }
            .controlSize(.small)
            .disabled(environment.isBusy || environment.isRestoring || environment.isBackingUp)
            Button("삭제") {
                environment.deleteBackup(backup)
            }
            .controlSize(.small)
            .disabled(environment.isBusy || environment.isRestoring || environment.isBackingUp)
        }
    }
}
