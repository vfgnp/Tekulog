# 探索マップ作り直し + カレンダータブ移動 — 詳細設計書

- 作成日: 2026-09-30
- 前提: `01-requirements.md` / `02-basic-design.md`
- 本書は実装単位(ファイル・型・関数・アルゴリズム・テスト)を定める。

## 0. ファイル一覧

| ファイル | 区分 | 内容 |
|---|---|---|
| `Tekulog/Services/ExplorationGrid.swift` | 新規 | グリッド定義(純関数) |
| `Tekulog/Services/FogCellIndex.swift` | 新規 | セルの空間索引 + LOD、`FogPainter` |
| `Tekulog/Services/OutingPostProcessor.swift` | 新規 | 外出1件の確定後処理(排他ゲート内) |
| `Tekulog/Views/ExploreFogMap.swift` | 新規 | `MKMapView` ラッパ、`FogOverlay`、`FogOverlayRenderer`、注釈 |
| `Tekulog/Services/ExplorationService.swift` | 変更 | グリッド委譲、`fetchAllCells` / `resetAllCells`、排他ゲート、再構築状態、フロンティア判定、`recordVisited` の取得を1回に |
| `Tekulog/Services/ExplorationBackfillService.swift` | 変更 | グリッド再構築 |
| `Tekulog/Services/SessionCoordinator.swift` | 変更(最小) | 確定後処理の呼び出し先を `OutingPostProcessor` に差し替え |
| `Tekulog/Persistence/WalkRepository.swift` | 変更 | `fetchFinalizedSessions` / `setExploredNewCellCount` 追加 |
| `Tekulog/Services/Tunables.swift` | 変更 | 定数追加 |
| `Tekulog/Views/ExploreMapView.swift` | 変更 | 地図部分を `ExploreFogMap` に置換、更新中表示 |
| `Tekulog/Views/MainTabView.swift` | 変更 | 4タブ化 |
| `Tekulog/Views/HomeView.swift` | 変更 | カレンダーアイコン削除 |
| `TekulogTests/*.swift` | 新規/変更 | §12 |
| `Tekulog.xcodeproj` | 再生成 | `xcodegen generate`(`project.yml` は変更なし) |

変更しないもの: `TekulogApp.swift`(既存の `ExplorationBackfillService(...).runIfNeeded()` 呼び出しが再構築も起動する)、
`CalendarView.swift`、Core Data モデル、`Info.plist`、entitlements。

## 1. `Tunables` 追加(探索マップ節)

| 定数 | 値 | 意味 |
|---|---|---|
| `explorationRevealRadiusMeters` | `150` | 1セルが晴らす範囲の外周の実寸半径(m)。FR-3.1 |
| `explorationRevealSolidFraction` | `0.5` | 半径のうち完全に晴れる内側の割合(150m × 0.5 = 75m)。残りは外周に向かって線形にフォグへ戻る。FR-3.1 |
| `explorationMinRevealScreenRadius` | `4` | 晴れの画面上の最小半径(pt)。FR-4.1。タイル上では `FogPainter.tileScaleMargin` を掛けた大きさで描く(§8) |
| `explorationFogOpacity` | `0.55` | フォグ(黒)の不透明度。NFR-4 |

既存の `explorationCellSizeMeters = 75` などは変更しない。

## 2. `ExplorationGrid`(純関数・`enum`)

グリッド定義の唯一の実装。入力は座標だけで、自宅位置を取らない(FR-6.2)。

```swift
enum ExplorationGrid {
    struct Cell: Hashable, Sendable {
        let latBucket: Int32
        let lonBucket: Int32
        var key: Int64 { ExplorationGrid.key(latBucket: latBucket, lonBucket: lonBucket) }
        var center: CLLocationCoordinate2D { ExplorationGrid.center(latBucket: latBucket, lonBucket: lonBucket) }
    }
    static let metersPerDegreeLatitude = 111_320.0
    static var latCellDegrees: Double { Tunables.explorationCellSizeMeters / metersPerDegreeLatitude }
    static func lonCellDegrees(latBucket: Int32) -> Double
    static func lonBucket(longitude: Double, latBucket: Int32) -> Int32
    static func cell(for coordinate: CLLocationCoordinate2D) -> Cell
    static func center(latBucket: Int32, lonBucket: Int32) -> CLLocationCoordinate2D
    static func key(latBucket: Int32, lonBucket: Int32) -> Int64
}
```

アルゴリズム(`s = Tunables.explorationCellSizeMeters`):

1. `latCellDeg = s / 111_320`
2. `latBucket = floor(latitude / latCellDeg)`
3. **行の中心緯度** `rowLat = (latBucket + 0.5) * latCellDeg`
4. `lonCellDeg = s / (111_320 * max(cos(rowLat), 0.01))` ← 手順3の値だけで決まるので、同じ行の全点で同一(原因 E の修正点。旧実装は点自身の緯度を使っていた)
5. `lonBucket = floor(longitude / lonCellDeg)`
6. 中心 = `(rowLat, (lonBucket + 0.5) * lonCellDeg)` — セル番号だけの関数なので一意(FR-6.1b)。中心は手順2・5の区間の中点なので、再変換すると同じセルに戻る(FR-6.1c)
7. `key = (Int64(latBucket) << 32) | Int64(UInt32(bitPattern: lonBucket))`(既存と同じ詰め方)

セルの東西幅は行の中心緯度で 75m ちょうど、行の端でも誤差は 0.001% 未満(FR-6.1a)。
`max(cos, 0.01)` は極域でのゼロ除算防止(既存踏襲)。緯度 ±90°・経度 ±180° の範囲で `Int32` に収まる
(`latBucket` 最大 ≒ 13万、`lonBucket` 最大 ≒ 27万)。

## 3. `ExplorationService` の変更

既存の不変条件「init 時に作った単一 context の `perform` でのみ読み書きする」を維持する。

### 3.1 メソッド

| メソッド | 変更 |
|---|---|
| `bucket(for:)` | **削除**。呼び出し側は `ExplorationGrid.cell(for:)` を使う |
| `bucketKey(for:)` | **削除**(用途だったフロンティア判定を §3.3 に置き換えるため) |
| `recordVisited(coordinates:firstSeenAt:)` | (a) `CLLocationCoordinate2DIsValid` でない座標を除外 (b) `densify` 後に `ExplorationGrid.cell(for:)` で重複のないセル列を作る(初出順を保持) (c) **既存セルの確認を1回の fetch にまとめる**: 対象セルの `latBucket`/`lonBucket` の最小〜最大で範囲 fetch(辞書結果、2属性のみ)→ キー集合を作り、無いセルだけ insert (d) 1件以上追加したら save。戻り値は従来どおり新規セル数 |
| `fetchAllCells()` | **新規**。全 `ExploredCell` の中心座標を返す(辞書結果で `centerLatitude`/`centerLongitude` のみ取得) |
| `resetAllCells()` | **新規**。`NSBatchDeleteRequest` で `ExploredCell` を全削除し、直後に `context.reset()`(batch delete は context を経由しないため、登録済みオブジェクトを捨てる)。同じ context の `perform` 内で行う |
| `findFrontierCandidates(home:)` | 判定を §3.3 に変更 |
| `fetchCells(minLat:…)` / `explorationRate` / `densify` / `boundingBox` / `offset` / `totalExploredCellCount` | 変更なし |

(c) の理由: 再構築では全外出を再生するため、セルごとの fetch(現行)だと外出数×セル数ぶんの往復になる。
範囲 fetch は経路の外接矩形内の既存セルを余分に読むが、件数は高々数万で問題ない。

### 3.2 排他ゲートと再構築状態

```swift
/// 先着順の非同期ミューテックス。再入不可。
final class AsyncGate: Sendable {
    func acquire() async       // 空いていれば即取得、保持中なら待ち行列に入って中断
    func release()             // 待ちがあれば先頭を再開(保持を引き継ぐ)、なければ解放
}
```
実装: `OSAllocatedUnfairLock<State>`(`isHeld: Bool`, `waiters: [CheckedContinuation<Void, Never>]`)。
`acquire` は `withCheckedContinuation` 内でロックを取り、空きなら `isHeld = true` にしてロック外で即 resume、
保持中なら continuation を末尾に積む。`release` はロック内で先頭を取り出し、ロック外で resume する(取り出せなければ `isHeld = false`)。
キャンセルには対応しない(使用箇所の Task はキャンセルされない)。

`ExplorationService` に追加:
```swift
let outingGate = AsyncGate()                                   // 外出単位の排他(FR-6.7)
let rebuildState = CurrentValueSubject<Bool, Never>(false)     // 再構築中か(FR-6.9)。購読時に現在値が届く
```
`CurrentValueSubject` は `send` / `value` がスレッド安全で、購読した時点で現在値を流す。フラグの読み取りと変更通知の購読を
別々に行う方式(取りこぼしの余地がある)を避けるため、これ1つにまとめる。`ExplorationService` は既に `@unchecked Sendable`。

ゲートの規約: **保持するのは「再構築の全体」または「外出1件の確定後処理」**。保持中の処理は
`recordVisited` など非排他の API を直接呼ぶ(ゲートを二重に取らない)。

### 3.3 フロンティア判定(FR-7.3)

`findFrontierCandidates(home:)` の「未開拓」判定を、地点のセルが未開拓か → **地点から `explorationRevealRadiusMeters` 以内に
開拓済みセルの中心が無いか** に変える。

```
reveal = Tunables.explorationRevealRadiusMeters
box    = boundingBox(center: home, radiusMeters: frontierMaxRadius + reveal)
keys   = Set(fetchCells(box).map { ExplorationGrid.cell(for: $0).key })     // 中心→セルは往復一致(§2-6)
各方位・各刻みの地点 p について isRevealed(p) が false になった最初の地点を候補にする

isRevealed(p):
    n    = Int(ceil(reveal / cellSize)) + 1                                  // = 3
    base = ExplorationGrid.cell(for: p)
    for dLat in -n...n:
        row  = base.latBucket + dLat
        lonB = ExplorationGrid.lonBucket(longitude: p.longitude, latBucket: row)
        for dLon in -n...n:
            if keys.contains(key(row, lonB + dLon)),
               distance(ExplorationGrid.center(row, lonB + dLon), p) <= reveal: return true
    return false
```
方位数・刻み・最大半径(`Tunables`)と戻り値の型は変更しない。

## 4. `WalkRepository` の追加

```swift
/// 再構築(`ExplorationBackfillService`)が全確定外出を古い順に再生するためのスナップショット。
struct FinalizedSessionRef: @unchecked Sendable {   // NSManagedObjectID は不変でスレッド間共有可
    let id: NSManagedObjectID
    let kind: ActivityKind
    let startedAt: Date
    let totalDistance: Double
    let isClassified: Bool      // classifiedAt != nil
}
func fetchFinalizedSessions() async throws -> [FinalizedSessionRef]          // endedAt != nil, startedAt 昇順
func setExploredNewCellCount(sessionID: NSManagedObjectID, count: Int) async throws
func isClassified(sessionID: NSManagedObjectID) async throws -> Bool         // 削除済みなら true(処理不要)
func fetchRouteCoordinatesIfExists(for sessionID: NSManagedObjectID) async throws -> [CLLocationCoordinate2D]?   // 削除済みなら nil
```

`setExploredNewCellCount` は `exploredNewCellCount` だけを書く。`purpose` / `purposeIsUserSet` / `classifiedAt` には触れない(FR-6.5)。
**再構築(ゲート保持中)からしか呼ばない。**

「削除済み」の判定: `context.existingObject(with:)` は対象が無いと `NSManagedObjectReferentialIntegrityError`(Cocoa エラー 133000)を投げる。
新設の3メソッドはこのエラーだけを「削除済み」として扱い(`setExploredNewCellCount` は何もしない、`isClassified` は true、
`fetchRouteCoordinatesIfExists` は nil)、それ以外のエラーはそのまま投げる(再構築を中止させるため。§6)。
既存の `fetchRouteCoordinates(for:)` は変更しない。
外出削除系(`deleteSession`)には手を入れない(FR-6.8)。

既存メソッドの変更: `finalizeClassification` は (1) 対象が削除済みなら何もしない(上と同じ「削除済み」判定。再構築が未分類の外出を
分類している間(店舗検索の通信を待つ間)に削除されても、再構築を中止させないため)、(2) `purposeIsUserSet` が true のとき**目的を書かない**(新エリア数と `classifiedAt` は書く)。
`setPurpose`(利用者の手動変更)は `classifiedAt` を立てないため、未分類のうちに手動で目的を決めた外出へ後から自動判定が届くと上書きしてしまう。
保存完了通知を確定後処理より前に出すようにした(§5)ことで、「通知から詳細を開いて目的を変える」操作が先に終わる余地が広がるため、ここで塞ぐ(FR-6.5)。

## 5. `OutingPostProcessor`(新規・`struct`・`Sendable`)

`SessionCoordinator.classifyAndRecordExploration` の中身を移設し、排他ゲートを加えたもの。

```swift
struct OutingPostProcessor: Sendable {
    init(repository: WalkRepository, explorationService: ExplorationService)

    // ── ゲートを取る入口 ──
    /// ライブ確定用。経路が取得できなければ何もしない(既存挙動)。
    func processFinalized(sessionID:kind:startedAt:totalDistance:) async
    /// 未分類バックフィル用。経路が取得できなければ空の経路として分類まで行う(既存挙動。未分類のまま残すとループが終わらない)。
    func processBackfill(sessionID:kind:startedAt:totalDistance:) async
    // ── ゲートを取らない本体 ──
    /// 再構築用。**呼び出し側がゲートを保持していること**。失敗は投げる(再構築を中止させる)。
    func replayHoldingGate(_ session: FinalizedSessionRef) async throws
}
```

- 入口(`processFinalized` / `processBackfill`)の手順:
  1. `await explorationService.outingGate.acquire()` → `defer { release() }`
  2. **`isClassified(sessionID)` が true(または確認に失敗)なら何もせず return**(再構築が先に処理した外出の二重処理を避ける。
     再分類のための通信も省ける)
  3. 経路取得 → `classifier.classify(…, home: TekTheme.homeCoordinate())` → `recordVisited` → `finalizeClassification`
     (`classifiedAt == nil` のときだけ書く既存ガードは維持)。**`recordVisited` が失敗したら分類済みにせず終える**
     (未分類のまま残し、次回起動のバックフィルでやり直す。分類済みにすると、歩いた場所が晴れないまま固定される)。
     分類(通信で数秒かかりうる)は記録より前に済ませる: 記録と新エリア数の保存の間が空くと、その間にプロセスが終了したとき
     セルだけ保存済みで残り、やり直しでは新規 0 件と数えられて新エリア数が失われる
  入口は既存どおり失敗を握りつぶす(`try?`)。ライブ確定で反映が完了しなかった外出(ゲート待ち・通信中のプロセス終了、経路取得の失敗など)は
  未分類のまま残り、次回起動の未分類バックフィルが拾う(§6。バックフィルは起動のたびに未分類の有無を確認する)。
- 本体(`replayHoldingGate`)の手順: `fetchRouteCoordinatesIfExists` → nil(削除済み)なら return →
  `try recordVisited` → 分類済みなら `try setExploredNewCellCount`、未分類なら分類して `try finalizeClassification`。

`SessionCoordinator` の変更(この2点のみ):
1. プロパティ `classifier` を `postProcessor` に置き換え、`classifyAndRecordExploration` の本体を
   `await postProcessor.processFinalized(...)` の1行にする。
2. `finalize` 内の順序を「`finalizeSession`(外出の保存)→ **`notifyRecordingSaved`** → `classifyAndRecordExploration`」に入れ替える
   (現行は通知が最後)。通知の内容(種目・距離・歩数・ID)は確定後処理の結果を使わないので、ゲート待ちで遅らせない。

## 6. `ExplorationBackfillService` の変更(再構築)

```swift
static let gridVersionKey = "explorationGridVersion"
static let currentGridVersion = 2          // 1 = 旧グリッド(キー未設定も 1 とみなす)
init(explorationService:, repository: = WalkRepository(), defaults: UserDefaults = .standard,
     replay: (@Sendable (FinalizedSessionRef) async throws -> Void)? = nil)   // 既定は postProcessor.replayHoldingGate。テストで失敗を起こすための差し替え口
func runIfNeeded() async
```

```
runIfNeeded():
    if defaults.integer(gridVersionKey) < currentGridVersion:
        await rebuildGrid()
        guard defaults.integer(gridVersionKey) >= currentGridVersion else { return }   // 失敗 → 次回起動で再試行
    await backfillUnclassified()

backfillUnclassified():                                                                // 起動のたびに実行する
    var lastID: NSManagedObjectID? = nil
    loop:
        guard let next = try? await repository.fetchOldestUnclassifiedSession() else { return }   // 未分類なし、または取得失敗
        if next.id == lastID { return }                                                // 前回と同じ外出 = 処理が進んでいない → 中断(次回起動で再試行)
        lastID = next.id
        await postProcessor.processBackfill(next…)                                     // 1件ごとにゲート

rebuildGrid():
    await gate.acquire(); defer { gate.release() }
    guard defaults.integer(gridVersionKey) < currentGridVersion else { return }       // 版数の確認はゲート取得後(重複起動対策)
    explorationService.rebuildState.send(true); defer { explorationService.rebuildState.send(false) }
    do {
        try await explorationService.resetAllCells()
        let sessions = try await repository.fetchFinalizedSessions()
        for s in sessions { try await replay(s) }
        defaults.set(currentGridVersion, gridVersionKey)                               // 全件成功したときだけ
    } catch {
        AppLog.lifecycle.error(…)                                                      // 版数を進めず、次回起動で最初からやり直す
    }
```
(`defer` の実行順により、完了の発行(`send(false)`)はゲート解放の直前に出る。版数は発行より前に保存済み)

失敗時の方針(FR-6.6): セル全削除・外出一覧の取得・各外出の反映と保存のいずれかが失敗したら、その時点で中止して版数を書かない。
探索マップには途中までのセルが表示されるが、次回起動で全削除からやり直して正しい状態になる。
再構築中に削除された外出は失敗ではなく読み飛ばす(§4 の「削除済み」判定)。

FR-6.7 が成り立つ理由(外出 S が再構築と競合する全ケース):

| S の確定(`endedAt` 保存)と確定後処理の位置 | 経過 | 結果 |
|---|---|---|
| 確定後処理まで再構築より前に完了 | S は一覧に入り分類済み → 古い順の位置で `setExploredNewCellCount` | 正 |
| 確定は一覧取得より前、確定後処理がゲート待ち | S は一覧に入り未分類 → 再構築が分類+新エリア数を保存。その後ライブ側はゲート取得後の `isClassified` 確認で何もせず終わる(万一そこを通っても `finalizeClassification` は `classifiedAt` ガードで書かない) | 正 |
| 確定が一覧取得より後 | 一覧に入らない。ライブ側は再構築完了後に処理。S は最も新しい外出なので、全セルが戻った状態で数える | 正 |

その他の判断:
- **ヘッドレス再起動(SLC)中は再構築しない**(既存どおり UI の `.task` からのみ起動。FR-6.3)。それまでに確定した外出は新グリッドでセルを記録し、
  次に UI を開いたときの再構築で全体が作り直される(表の1行目)。
- 中断(アプリ終了)時は版数が旧のままなので、次回起動時に全削除からやり直す(冪等、FR-6.6)。
- 新規インストールでは外出0件で即完了し、版数だけ書き込まれる。
- **未分類バックフィルは「一度完了したら以後は見ない」フラグを持たない**(既存の `explorationBackfillCompleted` キーの読み書きをやめる)。
  未分類の外出は探索機能導入前のものだけでなく、確定後処理が完了しなかった場合にも後から生じる。フラグで打ち切ると、その外出は
  探索マップに晴れとして出ないまま残る。未分類が無いときのコストは fetch 1回。
- `ExplorationBackfillService` は `@unchecked Sendable` にする(保持するのは不変の参照のみ。テストで MainActor 外の Task から呼ぶため)。
- `runIfNeeded` が重複して呼ばれても、2つ目はゲート待ちの後に版数を再確認して何もしない。
- 未分類の外出の分類では従来どおり MapKit の店舗検索(通信)が走りうる。その間ゲートを保持する(NFR-7 で許容した遅延)。

## 7. `FogCellIndex`(値型・`Sendable`・不変)

```swift
struct FogCellIndex: Sendable {
    struct Point: Sendable { let x: Double; let y: Double; let pointsPerMeter: Double }   // MKMapPoint 座標系
    struct Level: Sendable {
        let squareSize: Double               // 升目の一辺(地図ポイント)
        let bucketSize: Double               // squareSize * 32
        let buckets: [Int64: [Point]]        // キー = (floor(y/bucketSize) << 32) | UInt32(floor(x/bucketSize))
        let maxPointsPerMeter: Double        // 全点の最大(最も北)。最大の晴れの半径(走査矩形の拡張量・マスクの粗さ)に使う
        let pointCount: Int
    }
    static let empty: FogCellIndex
    static let baseSquareSize = 512.0        // 地図ポイント。セル 75m(日本付近で約 560〜690 ポイント)より少し小さい
    static let maxLevel = 12                 // 512 * 2^12 ≒ 210万ポイント
    static let minSquareScreenPoints = 4.0   // 升目がタイル上これ以上になる最も細かいレベルを選ぶ

    let levels: [Level]                      // count == maxLevel + 1
    var cellCount: Int { levels[0].pointCount }

    init(coordinates: [CLLocationCoordinate2D])
    func level(forZoomScale zoomScale: Double) -> Int
    func forEachPoint(in rect: MKMapRect, level: Int, _ body: (Point) -> Void)
}
```

- レベル0: セル中心をそのまま `MKMapPoint` に変換した点。集約しない(位置・大きさとも正確)。`squareSize` は 512 として扱う。
- レベル k ≥ 1: 地図ポイントを `512 * 2^k` の升目に区切り、セルを1つ以上含む升目ごとに**升目の中心**を1点持つ(重複排除)。
- `pointsPerMeter` は `MKMapPointsPerMeterAtLatitude(その点の緯度)`。描画時の計算を避けるため構築時に持つ。
- `level(forZoomScale:)`: `512 * 2^k * zoomScale >= minSquareScreenPoints` を満たす最小の k(0...maxLevel にクランプ)。
  `zoomScale` は `draw` に渡る値(`MKZoomScale` = タイルのポイント / 地図ポイント。2の累乗の段階値)。
  → 1タイル(256pt 四方)に入る点は最大で (256/4)² = 4,096。表示時の拡大縮小には依存しない。
- `forEachPoint(in:level:)`: `rect` に交差するバケットだけを走査し、バケット内の全点を返す(円と矩形の交差判定は呼び出し側)。
  交差バケット数が 4,096 を超える場合は辞書全体を走査する(極端な入力への保険)。
- 無効な座標は構築時に捨てる。
- 構築は MainActor 外で行う(50,000 セル × 13 レベル)。

## 8. `FogPainter`(純関数・`enum`、`FogCellIndex.swift` 内)

```swift
enum FogPainter {
    struct Style: Sendable {
        var fogOpacity: Double
        var revealRadiusMeters: Double
        var solidFraction: Double
        var minScreenRadius: Double
        static var standard: Style { … Tunables から … }
    }
    static let tileScaleMargin = 2.0          // タイルが表示時に縮小されても画面上の最小半径を下回らないための係数
    /// 集約レベルで半径に足す量(升目の半対角)。レベル0は 0。
    static func padding(level: Int, squareSize: Double) -> Double
    /// 外周の半径(地図ポイント)。
    static func radius(pointsPerMeter: Double, squareSize: Double, level: Int, zoomScale: Double, style: Style) -> Double
    /// 外周の半径のうち完全に晴れる内側の割合。
    static func solidFraction(pointsPerMeter: Double, squareSize: Double, level: Int, style: Style) -> Double
    /// `context` は「地図ポイント座標系(原点=世界原点)」に変換済みであること。
    static func draw(index: FogCellIndex, mapRect: MKMapRect, zoomScale: Double, style: Style, in context: CGContext)
}
```

半径(地図ポイント):
```
pad   = level > 0 ? squareSize * 0.7072 : 0                          // 升目の半対角(元のセルが代表点から離れうる最大距離)
outer = max( pad + revealRadiusMeters * pointsPerMeter,               // 実寸 150m(FR-3.1, 3.2)+ 集約ぶん
             minScreenRadius * tileScaleMargin / zoomScale )          // 画面上の最小半径(FR-4.1)
solidFraction = (pad + revealRadiusMeters * style.solidFraction * pointsPerMeter) / (pad + revealRadiusMeters * pointsPerMeter)
```
- レベル0: `pad = 0` なので、完全に晴れる半径 75m・外周 150m の実寸どおり。
- 集約レベル: 完全に晴れる半径 = 半対角 + 75m、外周 = 半対角 + 150m。代表点から半対角以内にある元のセルの晴れ(75m / 150m)を
  必ず覆う。隣の升目(中心間隔 = 一辺)とは、完全に晴れる範囲(半径 ≥ 0.707 辺)どうしが必ず重なるので、連続した経路が途切れない。
- 下限が効く縮尺では、同じ割合のまま全体を拡大する(外周 = 下限、内側 = 下限 × solidFraction)。
- `tileScaleMargin = 2`: MapKit はタイルを2の累乗の縮尺で描いて表示時に拡大縮小する。実測(iOS 18.3 シミュレータ、画面幅 400m〜200km の
  15段階)では「実際の表示縮尺(`mapView.bounds.width / visibleMapRect.width`)/ `draw` の `zoomScale`」は 0.54〜0.98 で、
  タイルは常に細かい側で描かれ 0.5〜1 倍に縮小表示される。係数 2 で画面上の最小半径は 4〜8pt になり、`minScreenRadius`(4pt)を下回らない。
  集約(レベル1以上)が始まるのはタイル縮尺 1/256 以下 = 画面幅およそ 13km 超。初期表示(約 3km)はレベル0。

`draw`(フォグの濃さをアプリ側で計算し、1枚の画像にして貼る):

1. `saveGState`。CTM から「地図ポイントあたりのピクセル数」`s` を得る。CTM を `mapRect` の原点へ平行移動し
   (世界座標(最大約2.7億)をそのまま描画 API に渡さない)、`mapRect` でクリップする。
2. `k = index.level(forZoomScale:)`。そのレベルに点が無ければ、黒・`fogOpacity` で塗って終わり。
3. **マスクの粗さ**を決める。そのレベルの最大の晴れ(`maxPointsPerMeter` の点)について、外周半径 `R`・ぼかしの幅 `F = R × (1 − solidFraction)` を
   ピクセルに直し、格子1つの一辺を `D = clamp(floor(max(F/3, k > 0 ? R/5 : 0)), 1, 6)` ピクセルとする
   (縁のぼかしに格子が3つ以上入る粗さ。集約レベルはぼかしがほとんど無いので晴れの大きさを基準にする)。地図座標での格子間隔は `h = D / s`。
4. **格子は地図座標に固定**する: 第 i 列の中心は `x = (i + 0.5) × h`。`mapRect` を覆う範囲に、外側2格子ぶんの余白を足して確保する
   (補間が隣の格子点を参照するため)。格子がタイルの切り方に依らないので、隣り合うタイルは境界付近で同じ格子点の値を使い、継ぎ目が出ない。
5. 各格子点に「フォグが残る割合」(初期値 1)を持つ。走査矩形(`mapRect` を最大半径ぶん広げたもの)内の各点について、
   中心からの距離 `d` が 完全に晴れる半径以下なら 0、外周以上なら変更なし、その間は `(d − 完全に晴れる半径) / ぼかしの幅` を**掛ける**。
   重なる晴れは掛け算でつながる(`destinationOut` で重ね描きした場合と同じ結果)。半径と割合は点ごとに求める(緯度による差をそのまま反映)。
6. **集約レベルで `D > 1` のとき**は、完全に晴れる半径・外周の両方に `1.42 × h`(格子の対角)を足す。線形補間は、ある点を囲む4つの
   格子点すべての値を使う。その点が完全に晴れるには4点とも 0 である必要があり、最も遠い格子点は対角いっぱい(1.414h)離れている。
   対角ぶん広げておけば、本来完全に晴れる範囲(半対角 + 75m)にフォグが残らない。晴れが広がる量はタイル上で最大 約4pt(D = 6 のとき)。
   レベル0は実寸の正確さを優先して足さない。補間の誤差は縁のぼかしの折れ目(75m・150m 地点)で最大になり、フォグ濃度の 8% 以内
   (不透明度で約 0.05 以内。初期表示の縮尺では約 4%)。
7. 格子を RGBA(黒・premultiplied、アルファ = `fogOpacity × 残る割合`)の `CGImage` にし、補間品質 `.low`(線形)で格子の範囲へ1回描く。
   `draw(_:in:)` は画像の先頭行を矩形の maxY 側(地図では南)に描くので、行は南から順に詰める。
8. `restoreGState`。格子点数が上限(400万。想定外の描画要求への保険)を超える場合や画像を作れない場合は、フォグで塗るだけにする。

**この方式にした理由(実測)**: 当初は「全面をフォグで塗り、セルごとに放射グラデーションを `destinationOut` で描く」設計だった。
描画結果は正しかったが、Core Graphics は1回の描画ごとの準備コストが大きく、1タイルに約 3,000〜4,000 点が入る縮尺で
103〜115ms(グラデーションを `CGLayer` にして貼る方式でも 160〜176ms)かかり、NFR-1(50ms)を満たさなかった。
マスク方式は同じ条件で **9〜13ms**(開発機シミュレータ・Release 構成)。ただし計算が Swift のループなので、
最適化なし(Debug 構成)では 80〜570ms かかる。性能の判定は最適化ありのビルドで行う(要件 NFR-1 追補2)。

描画結果は `mapRect` の切り方に依存しない(各格子点の値は「その点に届く全セル」だけで決まり、走査矩形の拡張で取りこぼさない)。

判定点(`solidFraction = 0.5`、単独セルの場合): 0〜75m = α 0、110m ≒ 0.55 × (110−75)/75 ≒ 0.26、150m 以遠 = 0.55(AC-4)。

## 9. MapKit 層(`ExploreFogMap.swift`)

### 9.1 `FogOverlay`
```swift
final class FogOverlay: NSObject, MKOverlay, @unchecked Sendable {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
    private let state = OSAllocatedUnfairLock(initialState: State())   // State = 索引 + 最後に描いたタイルの縮尺
    var index: FogCellIndex { get / set(ロック越し) }
    var lastDrawnZoomScale: Double { get / set(ロック越し) }          // DEBUG の確認ログ用
}
```
`@unchecked Sendable` の根拠: 可変状態は `state` のみで、ロックで保護している。

### 9.2 `FogOverlayRenderer: MKOverlayRenderer`
```swift
override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
    guard let fog = overlay as? FogOverlay else { return }
    let index = fog.index                      // スナップショット取得(以後ロック外)
    FogPainter.draw(index: index, mapRect: mapRect, zoomScale: Double(zoomScale), style: .standard, in: context)
}
```
`boundingMapRect` が世界全体(原点 0,0)なので、レンダラの描画座標=地図ポイントそのもの(`point(for:)` は恒等)。
`MKOverlayRenderer` は MainActor 隔離されておらず(SDK ヘッダで確認)、`draw` は MapKit のバックグラウンドスレッドから複数同時に呼ばれる。
触るのは不変の `FogCellIndex` と引数の `context` だけ。

### 9.3 注釈
```swift
final class ExplorePinAnnotation: NSObject, MKAnnotation {
    enum Kind { case home, frontier }
    let kind: Kind; let coordinate: CLLocationCoordinate2D; let title: String?
}
```
`MKMarkerAnnotationView`: 自宅=`house.fill`・`TekTheme.primary`、フロンティア=`questionmark.circle`・`TekTheme.amber`。
`displayPriority = .required`(衝突回避で隠されない)。注釈は MapKit の仕様で常にオーバーレイより手前(FR-2.2)。

### 9.4 `ExploreFogMap: UIViewRepresentable`
```swift
struct ExploreFogMap: UIViewRepresentable {
    struct Pin: Identifiable, Equatable { let id: String; let latitude: Double; let longitude: Double; let title: String }
    struct CameraRequest: Equatable { let id: Int; let latitude, longitude, spanDegrees: Double }
    let home: CLLocationCoordinate2D
    let frontierPins: [Pin]
    let fogIndex: FogCellIndex
    let fogGeneration: Int            // 索引を差し替えるたびに +1(索引自体は比較しない)
    let cameraRequest: CameraRequest?
}
```
- `makeUIView`: `MKMapView` を**仮の大きさ(400×600)で**生成(大きさ 0 のまま領域を設定すると縮尺が決まらないため。
  SwiftUI が実際の大きさに直すとき中心と縮尺は保たれる)、`delegate = coordinator`、`FogOverlay` を `.aboveLabels`(地名ラベルより上。現行の見た目どおり地名ごと覆う)で追加、
  初期領域=自宅中心・span 0.03°(アニメなし、FR-7.5)、`showsUserLocation = false`、自宅注釈を追加。
  回転・ピッチは MapKit 既定(有効)のまま。
- `updateUIView`(MainActor):
  - `fogGeneration` が前回と違えば `overlay.index = fogIndex` → `renderer.setNeedsDisplay()`
  - 自宅座標が変わっていれば自宅注釈を差し替え
  - フロンティア注釈を `Pin.id` の集合で差分同期(増減分だけ add/remove)
  - `cameraRequest?.id` が前回と違えば `setRegion(..., animated: true)`(FR-7.3)
- `Coordinator: NSObject, MKMapViewDelegate`: `rendererFor overlay`(`FogOverlayRenderer` を生成して保持)、
  `viewFor annotation`。前回適用した `fogGeneration` / カメラ要求 ID / 自宅注釈 / フロンティア注釈(`Pin.id` → 注釈)を保持。
- フロンティアの `Pin.id` は「方位-距離」の文字列にする(読み込み直しても同じ地点なら同じ ID になり、マーカーが付け直されない)。
- DEBUG 限定: `regionDidChangeAnimated` で「表示縮尺(`bounds.width / visibleMapRect.width`)」と「最後に描いたタイルの `zoomScale`」を
  ログに出す(`tileScaleMargin` の実測用。§8)。

## 10. `ExploreMapView` の変更

削除: `camera` / `fogPoints` / `lastFetchedRegion` / `didInitialFit` / `fogOverlay(proxy:)` / `refreshFogIfNeeded` / `overlapRatio`、`MapReader`・`Map`・`Canvas`。

追加状態: `fogIndex = FogCellIndex.empty`、`fogGeneration = 0`、`cameraRequest: ExploreFogMap.CameraRequest?`、`cameraRequestSequence = 0`、`isRebuilding = false`、`reloadSequence = 0`。
追加環境値: `@Environment(\.scenePhase)`。

```swift
ZStack(alignment: .top) {
    ExploreFogMap(home: home, frontierPins: …, fogIndex: fogIndex, fogGeneration: fogGeneration, cameraRequest: cameraRequest)
        .ignoresSafeArea(edges: .top)
    VStack(spacing: 8) { explorationRatePill; if isRebuilding { rebuildingPill } }
}
.safeAreaInset(edge: .bottom, spacing: 0) { frontierSheet }
.task { await reloadAll(home: home) }                                               // (a) タブ表示のたび(FR-8.1)
.onChange(of: scenePhase) { _, phase in
    if phase == .active { Task { await reloadAll(home: home) } }                     // (b) フォアグラウンド復帰(FR-8.1)
}
.onReceive(service.rebuildState.receive(on: DispatchQueue.main)) { rebuilding in    // 購読時に現在値が届く
    let finished = isRebuilding && !rebuilding
    isRebuilding = rebuilding
    if finished { Task { await reloadAll(home: home) } }                             // (c) 再構築完了(FR-6.9)
}
```
- 再読込では `ExploreFogMap`(=`MKMapView`)は作り直されないので、(b)(c) では地図の表示位置が保たれる。
- 購読のスケジューラは `DispatchQueue.main`(`RunLoop.main` は地図のスクロール追跡中に配送されず、完了の反映が操作の終了まで遅れる)。
- 変化がないときの再読込を軽くする(フォアグラウンドへ戻るたびに走るため):
  - フォグ: 取得したセルの件数が前回地図へ渡したときと同じなら、索引の差し替え(=全タイルの再描画)を省く。セルは増える一方なので件数で判定できる。
    再構築完了時は中身が入れ替わっているので必ず差し替える。
  - フロンティア: 候補の ID(方位-距離)が前回と同じで地名を取得済みなら、逆ジオコーディングをやり直さず前回の地名を使う。
    地図のマーカーは、題名(地名)が変わったときは付け直す。
- `reloadAll(home:)`: `reloadSequence += 1` して連番を控え、`loadFog`・`loadExplorationRate`・`loadFrontierCandidates` を並行実行。
  **各読込は結果を状態へ代入する直前に「控えた連番 == 現在の `reloadSequence`」を確認し、違えば捨てる。**
  読込の契機は3つあって重なりうる(再構築中にタブを開いた直後に完了する、など)。先に始めた読込が後から終わったとき、
  途中までのセルで作った索引が最新の索引を上書きするのを防ぐ。
- `loadFog`: `fetchAllCells()` → `Task.detached { FogCellIndex(coordinates:) }.value` → 連番確認 → `fogIndex` 代入・`fogGeneration += 1`。
  取得失敗時は現在の索引を維持する。
- `rebuildingPill`: `ProgressView` +「開拓データを更新中…」の小さなカプセル(開拓率ピルと同じ配色)。
- フロンティア行タップ: `cameraRequestSequence += 1` → `cameraRequest = .init(id: 連番, 候補座標, span 0.01)`。
- **DEBUG 限定** `-demoFogCells N`(NFR-1 の実機目視用): `loadFog()` で、自宅を中心に N 個の合成セル(正方形に敷き詰め)を
  取得結果に**メモリ上で**加えて索引を作る。Core Data には書かない。開拓率・フロンティアには影響しない。
  生成関数は `ExplorationGrid.denseBlock(around:count:)`(性能テストを Release 構成でも走らせるので、関数自体は DEBUG 限定にしない。
  起動引数を読む側だけを `#if DEBUG` にする)。あわせて `-demoMapSpanDegrees X` で初期表示の範囲を変えられるようにする
  (simctl は地図を操作できないため。縮尺の実測とスクリーンショット用)。

ピル・シート・CTA・`compassLabel` / `distanceLabel` / `angularDifference` / `loadExplorationRate` / `loadFrontierCandidates` は現状維持。
`MainTabView` はタブ切替のたびに `ExploreMapView` を作り直すため、初期領域は毎回自宅中心になる(FR-7.5、現行と同じ)。

## 11. タブ移動

`MainTabView.swift`:
```swift
enum Tab: Int { case home = 0, calendar, exploreMap, myPage }
// content: case .calendar: NavigationStack { CalendarView() }
// tabBar : ホーム(house) / カレンダー(calendar) / 探索マップ(map) / マイページ(person)
```
冒頭コメントを4タブの説明に更新。`-initialTab N` は `Tab(rawValue:)` をそのまま使うので 0…3 に対応する(FR-1.4)。

`HomeView.swift`: `greeting` 内の `NavigationLink { CalendarView() }`(カレンダーアイコン)だけを削除する。
直前の `Spacer()` は挨拶を左へ寄せる役目があるので残す。
`CalendarView.swift` は変更なし(ナビバー非表示・自前ヘッダー・`navigationDestination` を既に持つ)。

## 12. テスト設計(`TekulogTests/`)

| ファイル | テスト | 対応 AC |
|---|---|---|
| `ExplorationGridTests`(新規) | 同じ行の南端・北端・中央で、同一経度の点が同じセルになる(**旧実装では失敗する回帰テスト**。札幌・東京・那覇の3緯度) | AC-8 |
| | セル中心を再変換すると同じセル(多数のランダム点)。中心と元の点の距離がセル対角の半分以内 | AC-8 |
| | 同じセルに入る別々の点から求めた中心が一致 | AC-8 |
| | セルの東西幅が 75m ±1%(3緯度)。隣のセル(75m 先)は別セル。`key` の一意性 | AC-8 |
| | `cell(for:)` の引数が座標のみ(自宅の `UserDefaults` を変えても結果不変) | AC-9 |
| `FogCellIndexTests`(新規) | 空の索引、件数、無効座標の除外 | |
| | 任意の矩形・全レベルで、矩形内にあるセル(集約レベルではそのセルを含む升目の点)が必ず列挙される | AC-7 |
| | `level(forZoomScale:)` が縮尺に対して単調で 0…maxLevel に収まる。選ばれたレベルの升目は画面上 4pt 以上 | AC-18 |
| | 集約レベルでは点数が減り、どのセルもいずれかの点から `squareSize * 0.71` 以内にある | AC-6 |
| `FogPainterTests`(新規) | オフスクリーンのビットマップへ描き α 値を検査: 中心・50m・70m = 0、110m ≒ 0.26、160m・300m = 0.55 | AC-4 |
| | 集約レベルの完全に晴れる半径・外周が「半対角 + 75m / 150m」以上で、隣の升目と重なる(全レベル)。連続した経路がどの縮尺でも途切れない | AC-6, FR-4.1 |
| | 下限半径がタイル上で `minScreenRadius × tileScaleMargin`、2倍縮小されても画面上 4pt 以上 | AC-6 |
| | 縮尺3段階・描画範囲のずらしで、同じ地理座標の α が一致。縮尺を上げると晴れの画面上の半径が比例して大きくなる | AC-3, AC-4 |
| | タイルを2枚に分けて描いた結果が、1枚で描いた結果と全ピクセルで一致(許容誤差内) | AC-5 |
| | 極端な縮小でもセル位置の α がフォグ濃度より十分低い | AC-6 |
| | セル0件なら全面がフォグ濃度 | |
| | 50,000 セル(敷き詰め)で、各レベルの最悪縮尺のタイル1枚(512px 四方)の描画時間の平均が 50ms 以内。**Release 構成でのみ判定**し、Debug では計測値を出してスキップ扱いにする | AC-18 |
| | 北東にだけ2つ目のセルを置き、その位置が晴れ、南東・北西の対称位置がフォグであること(上下・左右が反転して描かれていない) | AC-3 |
| `ExplorationServiceTests`(更新) | 既存の `bucket` テストは `ExplorationGridTests` へ移管。`recordVisited` の新規/重複/無効座標、`fetchAllCells`、`resetAllCells` 後に0件かつ再記録できる | AC-10 |
| | フロンティア候補がどの開拓済みセル中心からも 150m 超。何も開拓していなければ全方位が最初の刻み(既存テスト維持) | AC-16 |
| | `AsyncGate`: 同時に複数から取得しても本体が重ならず、先着順に実行される | AC-12 |
| `ExplorationBackfillServiceTests`(新規) | 再構築: 旧グリッドのセルが残らない/新エリア数が古い順に再計算される/分類済みの `purpose`・`purposeIsUserSet`・`classifiedAt` が変わらない/未分類の外出は分類される/版数が保存される/2回目は再構築しない | AC-10 |
| | 中断状態(セルが一部だけ・新エリア数が途中まで書き換わった・版数未保存)から実行しても、素の状態からの結果と一致 | AC-11 |
| | 再構築と `OutingPostProcessor.processFinalized` を並行実行(反復)しても、セルに重複がなく、全外出の新エリア数が逐次実行の結果と一致 | AC-12 |
| | `rebuildState` が再構築中 true → 完了後 false を発行する。後から購読しても現在値が届く | AC-14 |
| | 再構築の途中で失敗(反映がエラー)した場合は版数が保存されず、再実行で正しい結果になる。再構築中に削除された外出は読み飛ばされ、再構築は完了する | AC-11 |
| | 再構築済みの状態で未分類の外出が残っていても、次回の `runIfNeeded` で処理される(完了フラグで打ち切らない) | FR-6.5 |
| `WalkRepositoryClassificationTests`(更新) | `finalizeClassification` が手動で決めた目的(`purposeIsUserSet`)を上書きしない。`fetchFinalizedSessions` の順序と未確定の除外、`setExploredNewCellCount` が他の属性に触れない。削除済みの外出に対して `isClassified` = true・`fetchRouteCoordinatesIfExists` = nil・`setExploredNewCellCount` が何もしない。外出を削除してもセル数が変わらない | AC-10, AC-13 |
| `OutingPostProcessorTests`(新規) | 入口: 未分類なら分類・セル反映・新エリア数保存を行う/処理済みなら何もしない(セルも増えない)/ゲート保持中は待つ。本体: 分類済みは新エリア数だけ更新/削除済みは読み飛ばす | AC-12 |
| `ExploreMapViewTests`(更新) | `overlapRatio` の3テストを削除(関数廃止)。ラベル系は維持 | |
| `MainTabViewTests`(新規) | `Tab` の rawValue が 0:home / 1:calendar / 2:exploreMap / 3:myPage | AC-1 |

テスト上の注意:
- `UserDefaults` は `UserDefaults(suiteName:)` で隔離する。
- 未分類バックフィルの「同じ外出が続けて返ったら中断」は、保存の失敗を決定的に起こせないため自動テストの対象外(コードレビューで確認)。
- `viewContext` の `WalkSession` を直接読んで検証するテストクラスは `@MainActor` にし、並行実行は `Task.detached` で MainActor の外へ出す。
- 分類は MapKit の店舗検索(通信)を呼びうる。テストでは未分類の外出を `.running`(通信なしで `.run` に確定)にし、
  徒歩の外出はあらかじめ分類済みとして用意する。
- `FogPainterTests` の描画先は `CGContext`(RGBA 8bit、premultiplied)。CTM を「`zoomScale` 倍 → `-mapRect.origin` 平行移動」に設定して
  レンダラと同じ「地図ポイント座標系」にする。ビットマップは y 上向きなので、画素の読み出し側で行を反転する。

テストの実行:
- 通常(Debug 構成): `xcodebuild test -scheme Tekulog -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max'`
- 性能の判定(Release 構成): 上に `-configuration Release ENABLE_TESTABILITY=YES -only-testing:TekulogTests/FogPainterTests` を足す。

自動化できない項目(実機目視): AC-2、AC-3(操作中の追従)、AC-15、AC-17、AC-18 後段。差分レビュー: AC-19、AC-20、AC-22。
実機で操作感を確かめるときは最適化ありのビルドを使う(Debug 構成はフォグの描画が数十倍遅い)。DEBUG 起動引数も使う場合は
`-configuration Release SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG` でビルドする。

## 13. レビュー記録

### 第1回(2026-09-30、独立レビュアー)— 判定: 要修正(中1件 / 軽微5件)

グリッド、範囲 fetch、フロンティア判定(9,000点の総当たり比較で不一致0)、Swift 6 適合(型検査)、FR-6.7 の表、集約半径は問題なしと確認。

| # | 指摘 | 対応 |
|---|---|---|
| 1 | 「失敗した外出は次回の未分類バックフィルが拾う」が成り立たない(完了フラグで打ち切られる) | 完了フラグ(`explorationBackfillCompleted`)の読み書きをやめ、起動のたびに未分類を確認する(§6)。テストを追加(§12) |
| 2 | `HomeView` の `Spacer()` を消すと挨拶が中央寄せになる | `NavigationLink` だけ削除し `Spacer()` は残す(§11) |
| 3 | 手動で決めた目的を自動分類が上書きする経路がある | `finalizeClassification` は `purposeIsUserSet` なら目的を書かない(§4)。テストを追加 |
| 4 | 再読込が重なると古い結果で上書きされうる。購読は `DispatchQueue.main` が適切 | 読込の連番を確認してから反映(§10)。`receive(on: DispatchQueue.main)` に変更 |
| 5 | 集約レベルの `solidFraction` の代表値がレベル全体の最大で、南側で数m足りない | 描画方式の変更(§8)に伴い、半径と割合を点ごとに求めるようにした(代表値を使わない) |
| 6 | 大きさ 0 の時点で初期領域を設定している | 仮の大きさ(400×600)で生成してから設定(§9.4)。シミュレータで初期表示が自宅中心・約 3km になることを確認 |

### 実装工程の実測による変更(第1回レビュー後)

- §8: 描画方式を「セルごとの放射グラデーション」から「マスクを計算して1枚の画像で貼る」に変更(性能。経緯は §8 に記載)。
- §8: `tileScaleMargin = 2` を実測で確定。
- §6 / §12: 再構築の失敗をテストで起こすため、`ExplorationBackfillService` に再生処理の差し替え口(`replay` 引数、既定は `OutingPostProcessor.replayHoldingGate`)を追加。
- §12: 性能テストは Release 構成で判定(要件 NFR-1 追補2)。

### 第2回(2026-09-30、同レビュアー)— 判定: 要修正(軽微1件)

第1回の6件はすべて解消と確認。描画方式の変更(継ぎ目・行の詰め順・格子の粗さ・レベル0の誤差)、Release 構成での判定、
`tileScaleMargin = 2` と約 13km の整合、`replay` 差し替え口は妥当と確認。新規1件:

| # | 指摘 | 対応 |
|---|---|---|
| 1 | 集約レベルで足す「0.75h」の根拠が誤り。線形補間は囲む4格子点すべてを使うので、最も遠い格子点は対角(1.414h)。0.75h では完全に晴れる範囲の縁にフォグ濃度の約2%が残る | 足す量を `1.42 × h` に変更(§8 手順6、実装も同じ)。レベル0の補間誤差の見積もりも試算値(8% 以内)に直した。テストの許容誤差を 0.02 → 0.004 に詰めた |

### 第3回(2026-09-30、同レビュアー)— 判定: 指摘なし(承認)

第2回の1件は解消、修正による新たな問題なし。

### 実装の第三者レビューを受けた設計書の更新(2026-10-01)

実装レビュー(記録は `04-verification.md` §5)の指摘に合わせて、§3.2(`isRebuilding` の削除)、§4(`finalizeClassification` は削除済みなら何もしない)、
§5(記録に失敗したら分類済みにしない・分類 → 記録 → 保存の順)、§9.1(`FogOverlay` の状態)、§10(変化がないときの再読込の軽量化)を実装に合わせた。
