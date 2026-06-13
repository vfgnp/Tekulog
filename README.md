# Tekulog

毎日の **散歩・自転車移動** を自動で記録する iOS ネイティブアプリ。運動量(歩数・距離・ペース・消費エネルギー)と GPS ルートを **端末内だけ** に保存する、完全クラウドレス設計。

> 設計の出発点は [`walking-tracker-spec.md`](./walking-tracker-spec.md) を参照。

## コンセプト

- **完全クラウドレス**:自前バックエンドを持たない。位置情報・運動データは一切開発者サーバーに送らず端末内に閉じる。App Store プライバシー表示で **"Data Not Collected"** を目標とする。
- **自動記録**:起動を忘れても大丈夫。Core Motion が歩行/自転車を検知すると自動で記録を開始し、移動が 30 分以上止まると自動で確定保存する。
- **対象端末**:iPhone XR(iOS 18)。Deployment Target は **iOS 18**。

## 主要技術

| 領域 | 採用 |
|------|------|
| 活動検知(歩行/自転車) | Core Motion `CMMotionActivityManager` |
| 運動量(歩数・距離・ケイデンス) | Core Motion `CMPedometer` |
| 位置取得 | Core Location `CLLocationUpdate.liveUpdates()` |
| ルート保存 | Core Data(端末内、`NSFileProtectionComplete`) |
| 運動データ集約 | HealthKit(`HKWorkout` 書き込み) |
| 地図表示 | MapKit(SwiftUI `Map` + `MapPolyline`) |
| UI | SwiftUI |

## 記録のしくみ

```
低電力トリガー層              セッション層(検知後のみ稼働)
ActivityDetector  ──start──▶  LocationTracker (GPS)
(CMMotionActivity)            PedometerService (歩数/距離/ペース)
        │                              │
        └──停止30分──▶  SessionCoordinator ──▶ Core Data 保存
                               │                └─▶ HealthKit Workout
                               └─▶ ローカル通知(開始/保存)
```

- 開始:`walking` を連続 3 分、または `cycling` を連続 2 分 検知(`Tunables` で調整可)。`automotive`(車・電車)/ `stationary` は除外。
- 終了:`stationary`/`automotive` が 30 分継続したら自動確定。
- 自動開始・保存時はローカル通知で知らせ、誤検知ならその場で手動破棄できる。

## ⚠️ ビルドには Xcode が必要

このリポジトリは **ソース一式 + 設定 + [XcodeGen](https://github.com/yonyz/XcodeGen) 定義(`project.yml`)** を含む。実ビルド・実行には **フルの Xcode(iOS 18 SDK)** が必要(Command Line Tools のみでは不可)。

### セットアップ

```bash
# 1. XcodeGen で .xcodeproj を生成
brew install xcodegen
xcodegen            # project.yml から Tekulog.xcodeproj を生成

# 2. Xcode で開く
open Tekulog.xcodeproj
```

XcodeGen を使わない場合は、Xcode で新規 iOS App プロジェクトを作り、`Tekulog/` 配下のソースと `Resources/` を取り込み、後述の Capabilities / Info.plist キーを手動設定する。

### 必要な Capabilities / 権限

- Background Modes → **Location updates**
- HealthKit(`Tekulog.entitlements`)
- Info.plist 利用目的キー:
  - `NSLocationWhenInUseUsageDescription`
  - `NSLocationAlwaysAndWhenInUseUsageDescription`
  - `NSMotionUsageDescription`
  - `NSHealthShareUsageDescription` / `NSHealthUpdateUsageDescription`

### 実機確認(推奨)

シミュレータは Core Motion の活動種別を返さないため、**iPhone XR 実機** で実際に歩く/自転車に乗って、自動開始 → ルート描画 → 30 分停止での自動保存 → HealthKit 反映 → 通知、を確認する。

## プロジェクト構成

```
Tekulog/
  App/            アプリエントリ(TekulogApp.swift)
  Models/         Core Data モデル, ActivityKind
  Persistence/    PersistenceController, WalkRepository
  Services/       ActivityDetector / LocationTracker / PedometerService
                  SessionCoordinator / HealthKitService / NotificationService / Tunables
  ViewModels/     画面ロジック
  Views/          SwiftUI 画面
  Resources/      Info.plist, Tekulog.entitlements
```

## 既知の制約 / 今後

- **アプリ強制終了からの自動復帰は初版スコープ外**。`CMMotionActivityManager` 単体では kill 後に自動起動できない。完全な復帰には significant-location-change / `CLMonitor` 監視で iOS にアプリを再起動させるフェーズ2拡張が必要。
- at-rest 暗号化(CryptoKit AES-256-GCM)は後回し。初版は iOS の Data Protection に委ねる。
- 同期/バックアップが必要になった場合のみ CloudKit **private** database を検討(自前 API は採らない)。

## ライセンス

未定。
