# 散歩記録アプリ 仕様書 / Claude Code 引き継ぎドキュメント

> このドキュメントは、アプリの設計方針を Claude Code に引き継ぐための仕様書です。
> プロジェクトルートに `SPEC.md` または `CLAUDE.md` として配置して読み込ませてください。

---

## 1. アプリ概要

毎日の散歩を対象に、以下を記録する iOS ネイティブアプリ。

- **運動量**(歩数・距離・ペース・消費エネルギー)
- **移動ルート**(GPS による緯度経度の軌跡)

## 2. 最重要の設計方針:完全クラウドレス

**自前バックエンドは作らない。** 位置情報・運動データはすべて端末内に閉じる。

理由:位置ルートを開発者側サーバーに集めた時点で、APPI(個人情報保護法)上の「取得・利用目的の通知/公表・安全管理措置・プライバシーポリシー整備」等の事業者義務が発生する。これを構造的に回避するため、データを開発者が一切受け取らない設計にする。

- App Store のプライバシー栄養表示で **"Data Not Collected"** を表明できる状態を目標とする。
- 将来どうしても同期/バックアップが必要になった場合のみ、**CloudKit private database** を使う(ユーザー自身の iCloud アカウント内に保存され、開発者は他人の private データを読めない=「取得」に当たらない)。自前API/サーバーは選択肢に入れない。

## 3. ターゲット環境

- **対象端末:iPhone XR**(A12 Bionic / M12 モーションコプロセッサ統合 / GPS・GNSS 搭載)
- **OS制約:iPhone XR の最終対応は iOS 18 で打ち止め**(iOS 26 以降にはアップグレード不可)。
  - iOS 17+ のモダンAPI(`CLLocationUpdate.liveUpdates()`、SwiftUI `Map` + `MapPolyline`)は **iOS 18 で動作するため使用可**。
  - **Deployment Target は要検討**。App Store 配布で古い端末も救うなら iOS 16〜17 あたりを天井候補とする(※ここは未確定。下記「未決事項」参照)。
- UI フレームワーク:**SwiftUI** を基本とする。

## 4. 技術スタック

| 領域 | 採用 | 備考 |
|------|------|------|
| 運動量(歩数・距離・ケイデンス) | **Core Motion / CMPedometer** | GPS 不要、消費電力ほぼゼロ |
| 運動データの集約・保存 | **HealthKit** | 端末内保持。iCloud同期はApple管理の暗号化同期で開発者は触れない |
| 位置情報取得 | **Core Location** | iOS 17+ は `CLLocationUpdate.liveUpdates()` を優先 |
| ルートデータ保存 | 端末内 **Core Data / SQLite / GPX** | `CLLocation`(緯度・経度・時刻)の配列を保存 |
| 地図表示 | **MapKit**(SwiftUI `Map` + `MapPolyline`) | タイルはAppleから取得するが、ルート座標はローカル描画のみ。Appleに送信されない |

## 5. バックグラウンド記録(技術的な要注意点)

散歩中に画面ロックしても記録を継続したい場合の設定:

- 権限:`.authorizedAlways`(または使用中+バックグラウンドインジケータ)
- `Info.plist` の `UIBackgroundModes` に `location` を追加
- `allowsBackgroundLocationUpdates = true`
- バッテリー対策:`activityType = .fitness`、`distanceFilter` 調整、精度調整

### 推奨アーキテクチャ:セッション型

常時追跡ではなく「**散歩セッション開始 → 終了**」のセッション型にする。必要な時だけGPSを回すことで:

- 消費電力を最小化(iPhone XR は2018年発売でバッテリー劣化の可能性あり)
- Strava 等フィットネス系アプリと同じ堅実な設計

## 6. ローカルデータのセキュリティ

開発者に送らなくても、**端末内の位置履歴自体が機微情報**である前提で扱う。

- iOS の Data Protection(`NSFileProtectionComplete`)でロック時は自動暗号化される。
- Core Data ストアに保護クラスを明示する。
- さらに堅牢にするなら、**CryptoKit(AES-256-GCM)で at-rest 暗号化**を一枚かぶせる。

## 7. Info.plist 必須キー(利用目的説明)

- `NSLocationWhenInUseUsageDescription`
- `NSLocationAlwaysAndWhenInUseUsageDescription`
- `NSMotionUsageDescription`
- HealthKit 関連(`NSHealthShareUsageDescription` / `NSHealthUpdateUsageDescription`)
- HealthKit を使う場合は Capabilities で HealthKit を有効化

## 8. 未決事項(Claude Code 作業前に確定したい点)

1. **Deployment Target をいくつにするか**(XR以外にどこまで古い端末を救うか)。
2. **記録方式**:セッション型(開始→終了)で確定とするか、常時バックグラウンド追跡も併用するか。
3. ルートデータの**保存形式**(Core Data / SQLite / GPX のどれを第一候補にするか)。
4. at-rest 暗号化(CryptoKit レイヤー)を**初版から入れるか、後回しにするか**。

---

## Claude Code への最初の指示(例)

```
この SPEC.md を読んで、散歩記録アプリの Xcode プロジェクトの初期構成を作って。
- SwiftUI ベース
- 完全クラウドレス(自前バックエンドなし)
- まずはセッション型の記録(散歩開始→終了)から実装
- CMPedometer による歩数取得と、Core Location によるルート記録の最小構成
- Info.plist の利用目的キーと Capabilities も設定して
未決事項(セクション8)については、実装前に確認の質問をして。
```
