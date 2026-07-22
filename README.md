# SNS Downloader

X (Twitter) / Instagram / TikTok / YouTube / pixiv の画像・動画を写真ライブラリに一括保存する個人用 iOS アプリ。

## 機能

- **本体アプリ**: 投稿 URL をペースト(複数行 OK)→ 一括ダウンロード → 写真アプリに保存
  - 起動・前面復帰時、クリップボードに URL があれば入力欄へ自動ペースト
- **共有シート拡張**: X / Instagram / TikTok / pixiv アプリや Safari で「共有」→「SNSに保存」→ その場で保存
- 進捗表示・失敗時のリトライ付き

## 対応 URL と取得方法

| プラットフォーム | 対応内容 | 取得経路 |
|---|---|---|
| X (x.com / twitter.com) | 画像(複数枚可)・動画・GIF、オリジナル解像度 | FxTwitter API (api.fxtwitter.com) |
| Instagram(ログイン時) | カルーセル全枚数・非公開(フォロー中)含む画像・動画 | 公式 Web API + セッション Cookie |
| Instagram(未ログイン) | フィード画像・リール動画の 1 枚目のみ(公開投稿) | InstaFix ミラー (kkinstagram.com) → og タグ fallback |
| TikTok | 動画(HD・透かしなし)・画像スライドショー、短縮リンク (vm.tiktok.com) 可 | tikwm.com API |
| YouTube | 動画・Shorts(watch / youtu.be / shorts / live / embed 形式)、最高画質(通常 1080p) | YouTube 内部 player API (Innertube) + 映像・音声の合成 |
| pixiv | イラスト・マンガの全ページ(オリジナル解像度)、うごイラ(mp4 に変換)、R-18 等(ログイン時) | pixiv AJAX API (www.pixiv.net/ajax) + セッション Cookie + うごイラ ZIP の展開・動画化 |

### Instagram ログイン

アプリの設定(歯車アイコン)→「Instagramにログイン」でアプリ内 WebView からログインすると、
セッション Cookie が Keychain に保存され(アプリ・共有拡張で共有)、公式 Web API 経由で
カルーセル全枚数・フォロー中の非公開アカウントの投稿が取得できるようになります。
セッションが切れたら匿名方式に自動フォールバックするので、再ログインしてください。

非公式クライアント扱いになるため、アカウント制限のリスクはゼロではありません。
気になる場合はダウンロード用のサブアカウントでログインしてください。

### pixiv ログイン

アプリの設定(歯車アイコン)→「pixivにログイン」でアプリ内 WebView からログインすると、
セッション Cookie (`PHPSESSID`) が Keychain に保存され(アプリ・共有拡張で共有)、
R-18・R-18G などログインが必要な作品も取得できるようになります。
pixiv 側の設定で「性的コンテンツを表示する」を有効にしておいてください。
公開作品のダウンロードだけならログインは不要です。

### 既知の制限

- Instagram 未ログイン時はカルーセルの 1 枚目のみ・公開投稿のみ
- YouTube は映像・音声を別々にダウンロードして再エンコードなしで合成します。
  画質は H.264 で配信される最高解像度(通常 1080p)まで。4K などは VP9/AV1 のみの
  配信で iOS では再エンコードなしの合成ができないため対象外。
  年齢制限付き・メンバー限定・ライブ配信中の動画は取得できません
- YouTube は動画や回線によって高画質ストリームの全量取得を拒否することがあります
  (PO トークンなしの URL への規制)。その場合は取得できる範囲で最も高い画質
  (最低 360p)に自動で切り替えます
- 外部サービス(fxtwitter / kkinstagram / tikwm)が停止・仕様変更すると匿名経路は動かなくなります
  (2026-07 時点で全経路の動作確認済み)。壊れたら `Shared/Extractors/` 内の該当ファイルを直してください
- pixiv は未ログインだと公開作品のみ取得できます。R-18・R-18G やフォロワー限定などは
  設定から pixiv にログインすると取得できます(未ログインだと「ログインが必要」エラーになります)。
  うごイラは各フレームの表示時間を保ったまま mp4 に変換して保存します。作品選択画面では
  サムネイルのプレビューは表示されません(pixiv の画像 CDN が Referer を要求し、
  プレビューの画像読み込みが 403 になるため)。「全選択」で一括保存してください

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

### 証明書失効対策(AltStore で自動再署名)

無料 Apple ID で Xcode から直接入れると、プロビジョニングが **7 日で失効**して
毎週入れ直すことになる。これを避けるため、**AltStore** に未署名の `.ipa` を食わせて入れると、
期限が切れる前に**同一 Wi-Fi 上でバックグラウンド自動再署名(リフレッシュ)**してくれる。
署名は AltStore があなたの Apple ID で行うので、Xcode の署名設定は不要。

> Mac が家にあり同じ Wi-Fi に定期的に繋がる前提の手順。週に一度も Mac と同 Wi-Fi に
> 繋がらないと期限切れになる点に注意(長期外出が多いなら SideStore が向く)。
> 有料 Apple Developer Program($99/年)を使えば失効が 7 日 → 1 年に延び、ほぼ放置できる。

#### 1. 未署名 `.ipa` を書き出す

```bash
cd sns-downloader
scripts/build-ipa.sh      # dist/SNSDownloader.ipa を生成(署名なし)
```

> `scripts/build-ipa.sh` は `CODE_SIGNING_ALLOWED=NO` でビルドするため、証明書もチーム ID も不要。
> インストール時に AltStore があなたの Apple ID で署名する。

#### 2. AltServer を Mac に導入(初回のみ)

1. [altstore.io](https://altstore.io) から **AltServer(Mac 版)** をダウンロードして
   `/Applications` に入れ、起動する(メニューバーに AltStore アイコンが出る)。
2. iPhone を USB で Mac に接続し、Finder で「このコンピュータを信頼」を許可。
3. メニューバーの AltStore アイコン → **Install AltStore → (自分の iPhone)** を選択。
4. Apple ID / パスワードを求められたら入力(この ID で署名される。無料 ID で可)。
5. iPhone に **AltStore** アプリが入る。実機側で
   設定 → 一般 → VPN とデバイス管理 → 自分の Apple ID を「信頼」。

#### 3. `.ipa` を AltStore に取り込む

- **同一 Wi-Fi 経由で入れる場合(以降おすすめ)**:
  `dist/SNSDownloader.ipa` を iCloud Drive などに置き、iPhone の **AltStore → My Apps →
  左上「+」** から選択。
- **USB 接続で入れる場合**: iPhone を Mac に繋いだまま「+」から取り込むと確実。

#### 4. 自動更新を有効化(重要)

- iPhone の AltStore → **Settings** で **Background Refresh** を ON。
- 期限が近づくと、Mac(AltServer)と iPhone が**同じ Wi-Fi にいる間に自動で再署名**される。
  つまり Mac を家で起動しておけば、週1回でも同 Wi-Fi に繋がれば切れない。
- 手動で更新したいときは **My Apps** で SNSDownloader を長押し → **Refresh**。

#### 更新版を入れ直すとき

コードを直したら `scripts/build-ipa.sh` を再実行 → 新しい `.ipa` を同じ手順で
「+」から入れれば上書きされる(データは保持される)。

#### Xcode から直接入れる場合(従来手順)

- 実機側で 設定 → 一般 → VPN とデバイス管理 → 開発元を信頼 が必要
- 無料 Apple ID だとプロビジョニングは **7 日で失効**するので、切れたら Xcode から入れ直す

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
- コンテンツの自動取得は各プラットフォーム(X / Instagram / TikTok / YouTube / pixiv)の利用規約に
  抵触する可能性があります。利用は自己責任でお願いします
- 特に Instagram / pixiv のログイン機能は非公式クライアント扱いになるため、
  **アカウントが制限・停止されるリスク**があります
- 本アプリは第三者運営の外部サービス(fxtwitter / kkinstagram / tikwm)に依存しています。
  過度な負荷をかける使い方(大量・高頻度の自動取得など)は避けてください
- 作者は本ソフトウェアの利用によって生じたいかなる損害についても責任を負いません
  (詳細は [LICENSE](LICENSE) を参照)

## ライセンス

[MIT License](LICENSE)
