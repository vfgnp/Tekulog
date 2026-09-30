# 探索マップ作り直し + カレンダータブ移動 — 検証手順書

- 作成日: 2026-09-30
- 対象: `01-requirements.md` の受け入れ基準(AC-1〜AC-22)
- 自動テストで確認できるものと、実機でしか確認できないものを分けて記録する。

## 1. 自動テスト

```bash
export DEVELOPER_DIR=~/Desktop/Xcode.app/Contents/Developer

# 全テスト(Debug 構成)。性能テスト1件は Debug では判定せずスキップ扱いになる。
$DEVELOPER_DIR/usr/bin/xcodebuild test -project Tekulog.xcodeproj -scheme Tekulog \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max'

# 性能の判定(AC-18)。最適化ありのビルドで描画時間を測る。
$DEVELOPER_DIR/usr/bin/xcodebuild test -project Tekulog.xcodeproj -scheme Tekulog \
  -configuration Release ENABLE_TESTABILITY=YES \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' \
  -only-testing:TekulogTests/FogPainterTests
```

| AC | テスト |
|---|---|
| AC-1 | `MainTabViewTests` |
| AC-3(縮尺・描画範囲に依らない) | `FogPainterTests.testSameGeographicPointLooksTheSameAtDifferentZoomLevels` / `testResultDoesNotDependOnWhereTheDrawnRectStarts` |
| AC-4 | `FogPainterTests.testRevealProfileMatchesRealWorldDistances` / `testRevealGrowsOnScreenInProportionToZoom` |
| AC-5 | `FogPainterTests.testTwoAdjacentTilesMatchOneCombinedDrawing` |
| AC-6 | `FogPainterTests.testRevealStaysVisibleWhenZoomedFarOut` / `testFullyClearCoreIsNeverLostAtAggregatedZooms` / `testContinuousRouteStaysConnectedAtEveryZoom` / `testAggregatedRevealAlwaysCoversTheOriginalReveal` |
| AC-7 | `FogCellIndexTests.testRectQueryNeverMissesAPointInsideTheRectAtAnyLevel` / `ExplorationServiceTests.testFetchAllCellsReturnsEveryCellRegardlessOfLocation` |
| AC-8 | `ExplorationGridTests`(行内の固定・往復一致・中心の一意性・東西幅) |
| AC-9 | `ExplorationGridTests.testCellDoesNotDependOnHomeLocation` |
| AC-10 | `ExplorationBackfillServiceTests.testRebuildRecreatesCellsAndCountsWithoutTouchingPurposes` / `testSecondRunDoesNotRebuildAgain` |
| AC-11 | `ExplorationBackfillServiceTests.testRebuildFromInterruptedStateGivesTheSameResult` / `testFailedRebuildDoesNotAdvanceTheGridVersionAndTheNextRunRecovers` |
| AC-12 | `ExplorationBackfillServiceTests.testRebuildRacingWithLiveFinalizeMatchesSequentialReplay` / `ExplorationServiceTests.testAsyncGate…` / `OutingPostProcessorTests` |
| AC-13 | `WalkRepositoryClassificationTests.testDeletingASessionKeepsItsExploredCells` |
| AC-14(状態の発行) | `ExplorationBackfillServiceTests.testRebuildStatePublishesTrueThenFalseAndReplaysCurrentValueToLateSubscribers` |
| AC-16 | `ExplorationServiceTests.testFrontierCandidatesAreNeverInsideTheRevealedArea` / `testIsRevealedMatchesBruteForceDistanceCheck` |
| AC-18(計測) | `FogPainterTests.testDrawingOneTileWithFiftyThousandCellsStaysWithinBudget`(Release 構成) |
| AC-21 | 上記コマンドの全体結果 |

## 2. シミュレータで確認できること

この開発機(Intel Mac)のシミュレータは、拡大した縮尺で地図の陸地を赤一色に描く既知の不具合がある。
フォグとタブの表示は確認できるが、地図との位置関係の最終確認は実機で行う。

```bash
xcrun simctl launch <udid> com.vfgnp.Tekulog -didFinishOnboarding 1 -initialTab 2 \
  -homeLocationIsSet YES -homeLatitude 35.6812 -homeLongitude 139.7671 \
  -demoFogCells 3000 -demoMapSpanDegrees 0.2
```

| 起動引数(DEBUG 限定) | 意味 |
|---|---|
| `-initialTab N` | 0=ホーム / 1=カレンダー / 2=探索マップ / 3=マイページ |
| `-demoFogCells N` | 自宅の周囲に N 個の合成セルをメモリ上だけで足す(Core Data には書かない) |
| `-demoMapSpanDegrees X` | 探索マップの初期表示の範囲(度)。既定は 0.03(約 3km) |

タイルの縮尺と表示縮尺の関係(`FogPainter.tileScaleMargin` の根拠)は、デバッグログ「探索マップ縮尺」で確認できる
(`log stream --level debug --predicate 'subsystem == "com.vfgnp.Tekulog"'`)。

## 3. 実機(iPhone XR)での確認手順

以下の `<udid>` は実機の識別子(リポジトリが公開のため伏せている。値はローカルの CLAUDE.md にある)。

### 3.0 インストール前にデータを退避する(必須)

新しいビルドは、最初に画面を開いた時点で開拓済みセルを全削除して作り直し、全外出の新エリア数を書き換える。**元には戻せない**。
旧ビルドへ戻しても直らない(旧コードは新グリッドのセルを正しく扱えない)。実機は実データの入った1台だけなので、
インストールの前にアプリのデータを Mac へ退避しておく。

**退避の前に、記録中でないことを確かめてアプリを終了する**(アプリスイッチャーから終了。常駐アプリなので、動いたままだと
ストアの3ファイル(本体・-wal・-shm)をコピーしている途中に書き込みが入り、整合しない組を退避する恐れがある)。
退避が済むまでアプリを開かない。

```bash
export DEVELOPER_DIR=~/Desktop/Xcode.app/Contents/Developer
BACKUP=~/TekulogBackup-$(date +%Y%m%d-%H%M)
mkdir -p "$BACKUP"
# Core Data のストア(Library/Application Support)と設定(Library/Preferences。グリッドの版数を含む)
xcrun devicectl device copy from --device <udid> \
  --domain-type appDataContainer --domain-identifier com.vfgnp.Tekulog \
  --source "Library/Application Support" --destination "$BACKUP/Application Support"
xcrun devicectl device copy from --device <udid> \
  --domain-type appDataContainer --domain-identifier com.vfgnp.Tekulog \
  --source "Library/Preferences" --destination "$BACKUP/Preferences"
ls -lR "$BACKUP" | head    # Tekulog.sqlite / -wal / -shm があることを確認
```

戻すとき(想定外の結果になった場合):
1. アプリを**削除**する(設定は OS 側が値を保持しているため、ファイルを書き戻すだけでは反映されないことがある。削除すれば確実に消える)。
2. 旧ビルド(更新前のコミット)を入れ、**起動せずに**、退避した2つのフォルダを `devicectl device copy to`
   (同じ `--domain-type` / `--domain-identifier`、`--remove-existing-content true`)で書き戻す。
3. 端末を再起動してからアプリを開き、外出の一覧と探索マップが退避時の状態であることを確かめる。

ストアと設定は必ずセットで戻す(設定だけ新しいままだと、グリッドの版数 `explorationGridVersion` が「再構築済み」のまま残り、
後で新ビルドを入れ直したときに再構築が走らない)。この書き戻し手順は、この環境ではまだ実際に試していない。

### 3.1 ビルド

フォグの描画は最適化なし(Debug 構成)だと数十倍遅い。**操作感を確かめるときは最適化ありでビルドする**
(DEBUG 起動引数も使うので `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG` を足す):

```bash
DEVELOPER_DIR=~/Desktop/Xcode.app/Contents/Developer \
  ~/Desktop/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project Tekulog.xcodeproj -scheme Tekulog \
  -destination 'platform=iOS,id=<udid>' -configuration Release \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG \
  -derivedDataPath /tmp/tekulog_dev -allowProvisioningUpdates build
# インストールと起動は CLAUDE.md の手順どおり(成果物は Build/Products/Release-iphoneos/Tekulog.app)
```

### 3.2 確認項目

| # | 手順 | 期待する結果 | AC |
|---|---|---|---|
| 1 | アプリを起動し、タブバーを見る | 左から ホーム / カレンダー / 探索マップ / マイページ。各タブが開く | AC-1 |
| 2 | ホーム画面の右上を見る | カレンダーのアイコンが無い | AC-2 |
| 3 | 更新後の最初の起動で、すぐ探索マップを開く | 「開拓データを更新中…」が出て、消えたあと晴れ・開拓率・未踏エリアが表示される(外出が少ないと一瞬で終わる) | AC-14 |
| 3b | Console.app(サブシステム `com.vfgnp.Tekulog`)でログを見る | 「探索グリッド再構築: 開始 セッション数=N」の後に「探索グリッド再構築: 完了」が出ている(「失敗」が出ていない)。2回目の起動では出ない | AC-10 |
| 4 | 探索マップを開く | 自宅が中心、約 3km の範囲。歩いた道に沿って晴れている。自宅と「?」のマーカーがフォグより手前に見える | AC-15 |
| 5 | ピンチで拡大・縮小、ドラッグで移動、2本指で回転、2本指の上下ドラッグで傾ける | **操作中も**晴れが道路に貼り付いたまま動く。指を離した後もズレない。フォグや晴れの縁に、格子状の線や段差(描画単位の境目)が見えない | AC-3, AC-5 |
| 5b | 5 の操作中に Console.app でデバッグログ「探索マップ縮尺」を見る(Debug レベルの表示を有効にする) | 「比(表示/タイル)」が常に 0.5〜1 の範囲(シミュレータの実測 0.54〜0.98 と同じ)。外れる場合は `FogPainter.tileScaleMargin` を見直す | AC-6 |
| 6 | 歩いた道を拡大して見る | 道の両側およそ 75m が完全に晴れ、150m でフォグに戻る。拡大すると晴れも大きくなる。**見た目の広さが想定どおりか(オーナー確認)** | AC-4 |
| 7 | 大きく縮小する(市区町村〜都道府県が入る程度) | 歩いたエリアが消えずに見える。経路が点線状に途切れない | AC-6 |
| 8 | 縮小した後に遠くへ移動し、また戻る | 晴れが欠けない | AC-7 |
| 9 | 「まだ歩いていないエリア」の行をタップする | 地図がその地点へ移動する。マーカーは晴れていない場所に立っている | AC-15, AC-16 |
| 10 | 別のタブへ移って探索マップへ戻る | 自宅中心の表示に戻る | AC-15 |
| 11 | `-demoFogCells 50000` を付けて起動し、探索マップを操作する | 引っかかりなく動く | AC-18 |
| 12 | (次に歩いた後。CLAUDE.md の「ロックして歩く実地テスト」の手順で)保存完了の通知を確認し、探索マップを開き直す、または開いたままアプリへ戻る | 保存完了の通知が従来どおり届く(通知は確定後処理より前に出すよう順序を変えた)。その外出に目的と新エリア数が付いている。新しく歩いた場所が晴れ、開拓率が増えている。ホームの「新エリア」表示が出る | AC-17, AC-22 |

デバイスへの引数付き起動:
```bash
xcrun devicectl device process launch --terminate-existing --device <udid> \
  com.vfgnp.Tekulog -- -initialTab 2 -demoFogCells 50000
```

## 4. 差分レビューで確認すること

| AC | 確認 |
|---|---|
| AC-19 | `Tekulog/Resources/Info.plist` と `Tekulog.entitlements` に差分がない。新しい通信 API の呼び出しがない |
| AC-20 | `Tekulog/Models/Tekulog.xcdatamodeld` に差分がない |
| AC-22 | `SessionCoordinator.swift` の差分が、確定後処理の呼び出し先の差し替えと保存完了通知の順序だけ。`TekulogApp.swift` に差分がない(再構築は既存の独立 `Task` から起動) |

## 5. 実装の第三者レビュー記録

### 第1回(2026-10-01、独立レビュアー)— 判定: 要修正(中1件 / 軽微5件)

レビュアー自身が Debug 構成の全テスト(96件・失敗0・スキップ1)と Release 構成の `FogPainterTests`(9.4〜11.4ms)を再実行して確認。
既存機能への影響(AC-19 / 20 / 22)、並行性、設計書との一致、テストの質、規約は問題なしと確認。

| # | 指摘 | 対応 |
|---|---|---|
| 1 | 実機に入れる前のバックアップ手順がない(再構築は元に戻せない) | §3.0 に退避と戻し方を追加 |
| 2 | 再構築中に削除された外出で再構築が中止される経路が残っている(`finalizeClassification`) | 削除済みなら何もしないよう変更。テストを追加 |
| 3 | セルの記録に失敗しても分類済みになり、以後やり直されない | 記録に失敗したら分類済みにせず終える(次回起動でやり直す) |
| 4 | フォアグラウンドへ戻るたびの再読込が、変化がなくても全部やり直す(逆ジオコーディング・マーカーの題名・再描画) | 取得済みの地名を使い回す/題名が変わったマーカーは付け直す/セル件数が同じなら索引の差し替えを省く |
| 5 | 検証手順書の実機確認に不足(描画単位の境目、縮尺比、再構築ログ、保存完了通知) | §3.2 の 3b・5・5b・12 に追加 |
| 6 | 設計書・CLAUDE.md との細かな食い違い | 03 の該当箇所と CLAUDE.md(ローカル専用)を更新 |

### 第2回(2026-10-01、同レビュアー)— 判定: 要修正(軽微2件)

第1回の6件は解消と確認。新規2件:

| # | 指摘 | 対応 |
|---|---|---|
| 1 | 順序を「記録 → 分類」に変えたことで、記録と保存の間に通信が挟まり、その間の終了で新エリア数が失われる | 「分類 → 記録(失敗したら分類済みにしない)→ 保存」の順に戻した |
| 2 | 退避手順に「アプリを終了してから」がない。設定の書き戻しは反映されない可能性がある | §3.0 に、退避前の終了と、戻すときの「削除 → 旧ビルド → 書き戻し → 再起動」の手順を追加 |

### 第3回(2026-10-01、同レビュアー)— 判定: 指摘なし(承認)

第2回の2件は解消、修正による新たな問題なし。実機でしか確認できない項目(§3.2)はオーナーの確認待ち。
