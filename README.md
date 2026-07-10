# SNS Downloader

X (Twitter) / Instagram / TikTok の画像・動画を写真ライブラリに一括保存する個人用 iOS アプリ。

## 機能

- **本体アプリ**: 投稿 URL をペースト(複数行 OK)→ 一括ダウンロード → 写真アプリに保存
  - 起動・前面復帰時、クリップボードに URL があれば入力欄へ自動ペースト
- **共有シート拡張**: X / Instagram / TikTok アプリや Safari で「共有」→「SNSに保存」→ その場で保存
- 進捗表示・失敗時のリトライ付き

## 対応 URL と取得方法

| プラットフォーム | 対応内容 | 取得経路 |
|---|---|---|
| X (x.com / twitter.com) | 画像(複数枚可)・動画・GIF、オリジナル解像度 | FxTwitter API (api.fxtwitter.com) |
| Instagram(ログイン時) | カルーセル全枚数・非公開(フォロー中)含む画像・動画 | 公式 Web API + セッション Cookie |
| Instagram(未ログイン) | フィード画像・リール動画の 1 枚目のみ(公開投稿) | InstaFix ミラー (kkinstagram.com) → og タグ fallback |
| TikTok | 動画(HD・透かしなし)・画像スライドショー、短縮リンク (vm.tiktok.com) 可 | tikwm.com API |

### Instagram ログイン

アプリの設定(歯車アイコン)→「Instagramにログイン」でアプリ内 WebView からログインすると、
セッション Cookie が Keychain に保存され(アプリ・共有拡張で共有)、公式 Web API 経由で
カルーセル全枚数・フォロー中の非公開アカウントの投稿が取得できるようになります。
セッションが切れたら匿名方式に自動フォールバックするので、再ログインしてください。

非公式クライアント扱いになるため、アカウント制限のリスクはゼロではありません。
気になる場合はダウンロード用のサブアカウントでログインしてください。

### 既知の制限

- Instagram 未ログイン時はカルーセルの 1 枚目のみ・公開投稿のみ
- 外部サービス(fxtwitter / kkinstagram / tikwm)が停止・仕様変更すると匿名経路は動かなくなります
  (2026-07 時点で全経路の動作確認済み)。壊れたら `Shared/Extractors/` 内の該当ファイルを直してください

## ビルド手順

前提: Xcode(App Store からインストール)、[XcodeGen](https://github.com/yonaskolb/XcodeGen)(`brew install xcodegen`)

```bash
cd sns-downloader
xcodegen generate        # SNSDownloader.xcodeproj を生成(リポジトリには含まれない)
open SNSDownloader.xcodeproj
```

Xcode で:

1. **SNSDownloader** ターゲット → Signing & Capabilities → Team に自分の Apple ID を選択
   (**ShareExtension** ターゲットも同様に設定)。
   `xcodegen generate` し直すとこの設定は消えるので、面倒なら `project.yml` の
   `DEVELOPMENT_TEAM` 行を自分のチーム ID で有効化してください
2. Bundle Identifier は他人と衝突するので、`project.yml` の `PRODUCT_BUNDLE_IDENTIFIER` を
   自分のドメインに書き換えて `xcodegen generate` し直す
3. iPhone を接続して Run

### 無料 Apple ID で入れる場合の注意

- 実機側で 設定 → 一般 → VPN とデバイス管理 → 開発元を信頼 が必要
- プロビジョニングは **7 日で失効**するので、切れたら Xcode から入れ直す

## 使い方

- **アプリから**: URL をペースト(改行区切りで複数可)→「ダウンロード」
- **共有シートから**: 各アプリの共有ボタン → 「SNSに保存」→ 本体アプリが起動して即ダウンロード
  (初回は共有シートの「その他」からアクションの追加が必要な場合あり)
- 初回保存時に写真ライブラリへの追加許可を求められます(「追加のみ」権限)
- URL スキーム: `snsdl://download?url={投稿URL}` で外部からも起動できます(ショートカット連携などに)

## 構成

```
project.yml            # XcodeGen 定義(app + share extension の 2 ターゲット)
App/                   # 本体アプリ (SwiftUI)
ShareExtension/        # 共有シート拡張
Shared/                # 両ターゲット共通: 抽出・ダウンロード・写真保存
  Extractors/          #   プラットフォーム別の抽出ロジック
```

## 免責事項

- 本ソフトウェアは**個人のアーカイブ用途**(私的複製の範囲)を想定しています。
  ダウンロードしたコンテンツの著作権は各投稿者に帰属します。**再配布・転載はしないでください**
- コンテンツの自動取得は各プラットフォーム(X / Instagram / TikTok)の利用規約に
  抵触する可能性があります。利用は自己責任でお願いします
- 特に Instagram ログイン機能は非公式クライアント扱いになるため、
  **アカウントが制限・停止されるリスク**があります
- 本アプリは第三者運営の外部サービス(fxtwitter / kkinstagram / tikwm)に依存しています。
  過度な負荷をかける使い方(大量・高頻度の自動取得など)は避けてください
- 作者は本ソフトウェアの利用によって生じたいかなる損害についても責任を負いません
  (詳細は [LICENSE](LICENSE) を参照)

## ライセンス

[MIT License](LICENSE)
