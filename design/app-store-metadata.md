# App Store 提出用メタデータ(v1.0.0)

App Store Connect の各欄にコピペする原稿。

## 基本情報

| 欄 | 値 |
|---|---|
| 名前 | Tekulog |
| サブタイトル | 散歩・ランニングを自動で記録 |
| バンドルID | com.vfgnp.Tekulog |
| SKU | tekulog-001 |
| プライマリ言語 | 日本語 |
| カテゴリ(プライマリ) | ヘルスケア/フィットネス |
| カテゴリ(セカンダリ) | ライフスタイル |
| 価格 | 無料 |
| 配信地域 | 日本のみ |
| 年齢制限 | 4+(アンケートは全て「なし」で回答) |

## プロモーションテキスト(170字まで)

アプリを開かなくても、歩き出すだけで記録が始まる。散歩・ランニング・サイクリングの距離とルートを自動で残す、いちばん手間のかからない運動記録アプリです。

## 説明文

Tekulog(てくログ)は、散歩・ランニング・サイクリングを「自動で」記録するアプリです。

ポケットに iPhone を入れて歩き出すだけ。アプリを開く必要も、ボタンを押す必要もありません。画面をロックしたままでも、歩数・距離・ペース・消費エネルギー・移動ルートが自動で記録されます。

■ こんな人におすすめ
・散歩やランニングの記録を付けたいけれど、毎回アプリを操作するのが面倒
・気づいたら記録を忘れていた、をなくしたい
・自分がどこを歩いたか、地図で振り返りたい

■ 主な機能
・自動記録 — 歩き出し・走り出しを検知して記録を開始、立ち止まると自動で終了
・ルートマップ — 1日の移動ルートを地図で表示。通った場所の地名も自動で表示
・歩数リング — 1日の歩数と目標達成をひと目で確認
・カレンダー — 記録した日・目標達成した日をひと目で振り返り
・血めぐりスコア — 今日の運動が身体にどれだけ効いたかを楽しく数値化
・実績とレベル — 続けるほど貯まる「てくポイント」とバッジ
・ヘルスケア連携 — 記録したワークアウトをヘルスケア App に保存

■ プライバシー第一
Tekulog にはサーバーがありません。記録したデータはすべてあなたの iPhone の中だけに保存され、開発者を含む外部に送信・収集されることは一切ありません。アカウント登録も不要です。

■ ご注意
・自動記録には位置情報の「常に許可」と「モーションとフィットネス」の許可が必要です
・記録していない間も画面上部に位置情報マークが表示されますが、これはロック中の自動記録を支える省電力の待機動作です

## キーワード(100字まで、カンマ区切り)

散歩,ウォーキング,ランニング,ジョギング,サイクリング,歩数計,万歩計,GPS,ルート,自動記録,運動,健康,ヘルスケア,ダイエット,ログ

## URL

| 欄 | 値 |
|---|---|
| サポートURL | https://vfgnp.github.io/Tekulog/ |
| マーケティングURL | (空欄でよい) |
| プライバシーポリシーURL | https://vfgnp.github.io/Tekulog/privacy.html |

## App Privacy(プライバシー栄養表示)

- 「データの収集を行なっていますか?」→ **いいえ(データは収集されません)**
  - 位置情報・ヘルスケア・歩数はすべて端末内(Core Data / HealthKit)のみで完結し、開発者のサーバーは存在しない
  - 地図表示と逆ジオコーディングで Apple に座標が渡るのは「Apple のサービス側の処理」であり、開発者による収集には該当しない

## 輸出コンプライアンス

- Info.plist に `ITSAppUsesNonExemptEncryption = NO` 設定済み → 質問は表示されない(表示されたら「いいえ」)

## 審査メモ(Review Notes 欄にそのまま貼る)

```
This app automatically records walks/runs/cycling using Core Motion and GPS.
No account or login is required. No data is collected — everything stays
on-device (Core Data + HealthKit). There is no server/backend.

Why "Always" location permission:
The core feature is recording outings while the phone is locked and the app
is in the background (auto-start via motion detection). "When In Use" cannot
capture a walk that starts while the screen is locked. A persistent low-power
location session keeps the app alive so motion-based auto-start works; GPS at
full accuracy runs only during an active recording session.

How to test auto-recording:
1. Complete onboarding and grant Location "Always" + Motion & Fitness.
2. Lock the screen and walk continuously for about 2 minutes.
3. Recording starts automatically (notification appears); stop walking for
   a few minutes and it ends automatically.
Note: auto-start requires a real device (Core Motion activity is not
available in the Simulator). Manual recording is available via the center
record button.

日本語補足: 本アプリはロック中の自動記録がコア機能のため位置情報「常に許可」を
使用します。データ収集は一切なく、全データが端末内に保存されます。
```

## スクリーンショット(6.9インチ / 1320×2868)

`~/Desktop/TekulogScreenshots/` の以下を順に:
1. tab0.png — ホーム(歩数リング+血めぐりスコア)
2. tab2.png — マップ(ルート+通った場所) ※実機撮影から差し替え
3. tab1.png — カレンダー
4. tab3.png — マイページ(任意)

## リリース設定

- リリース方法: 審査通過後に**自動でリリース**(手動にしたければ提出画面で変更)
- バージョン: 1.0.0 / ビルド: 1
