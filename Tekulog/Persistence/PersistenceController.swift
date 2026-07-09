import CoreData

/// Core Data スタック。ストアは端末内のみ。
///
/// ファイル保護は `.completeUntilFirstUserAuthentication`(spec §6 の `.complete` から変更):
/// 本アプリの中核は「ロック中(ポケットの中)の自動記録」であり、`.complete` だと
/// ロック中はストアが読み書き不可 → バックグラウンド自動開始の Core Data 行作成が
/// 必ず失敗して記録が丸ごと discard される(2026-07-09 の実地ログで確認)。
/// このクラスでも再起動後の初回ロック解除までは暗号化されたままで、
/// バックグラウンド動作するアプリの標準的な保護レベル。
///
/// `@unchecked Sendable`: 保持する NSPersistentContainer 自体は Sendable ではないが、
/// 書き込みは常に専用 background context の `perform` 上で行うためスレッド安全。
struct PersistenceController: @unchecked Sendable {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    /// SwiftUI プレビュー / テスト用のインメモリスタック。
    static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let ctx = controller.container.viewContext
        let sample = WalkSession(context: ctx)
        sample.id = UUID()
        sample.startedAt = Date().addingTimeInterval(-1800)
        sample.endedAt = Date()
        sample.activityKind = .walking
        sample.totalDistance = 2100
        sample.totalSteps = 2850
        try? ctx.save()
        return controller
    }()

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "Tekulog")

        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("永続ストアの description が取得できません")
        }

        if inMemory {
            description.url = URL(fileURLWithPath: "/dev/null")
        } else {
            // ロック中の自動記録を成立させるため、ロック中も読み書き可能な保護クラスを使う
            // (.complete はロック中の書き込みが必ず失敗する。冒頭コメント参照)。
            description.setOption(FileProtectionType.completeUntilFirstUserAuthentication as NSObject,
                                  forKey: NSPersistentStoreFileProtectionKey)
            // 軽量マイグレーションを有効化。
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
        }

        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                // 端末内ストアの致命的読込失敗。開発中に気付けるよう停止。
                fatalError("Core Data ストアの読み込みに失敗: \(error), \(error.userInfo)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
    }

    /// バックグラウンドのルート追記・保存用 context を生成する。
    func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        return context
    }
}
