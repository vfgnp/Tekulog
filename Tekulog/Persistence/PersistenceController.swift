import CoreData

/// Core Data スタック。ストアは端末内のみ。ロック時暗号化のため
/// `NSFileProtectionComplete` を明示する(spec §6)。
struct PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    /// SwiftUI プレビュー / テスト用のインメモリスタック。
    static var preview: PersistenceController = {
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
            // ロック中は読み書き不可・暗号化。端末内位置履歴を保護する。
            description.setOption(FileProtectionType.complete as NSObject,
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
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    /// バックグラウンドのルート追記・保存用 context を生成する。
    func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }
}
