#!/usr/bin/env bash
#
# 新バージョンを公開する（AltStore カスタムソース経由の自動更新用）。
#
# これ 1 コマンドで:
#   1. バージョンを +1（project.yml の CFBundleShortVersionString / CFBundleVersion）
#   2. 未署名 .ipa をビルド（scripts/build-ipa.sh）
#   3. GitHub Release を作成して .ipa をアップロード
#   4. apps.json（AltStore ソース）を更新して push
#
# 実行後、iPhone の AltStore がソースから新バージョンを検知し、
# 自動 / ワンタップで更新される（USB もファイル選択も不要）。
#
# 使い方:
#   scripts/publish.sh              # パッチを自動で +1（例 1.0.1 -> 1.0.2）
#   scripts/publish.sh 1.1.0        # バージョンを明示指定
#
# 前提: gh (GitHub CLI) が認証済み。リポジトリが public であること。
#
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="TomPenguin/sns-downloader"
IPA="dist/SNSDownloader.ipa"
APPS_JSON="apps.json"
ICON_SRC="App/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
ICON="icon.png"

# --- 1. バージョン決定 ---
CUR_VER=$(grep -m1 'CFBundleShortVersionString:' project.yml | sed -E 's/.*"([0-9.]+)".*/\1/')
CUR_BUILD=$(grep -m1 'CFBundleVersion:' project.yml | sed -E 's/.*"([0-9]+)".*/\1/')

if [ "${1:-}" != "" ]; then
  NEW_VER="$1"
else
  IFS='.' read -r MA MI PA <<< "$CUR_VER"
  PA=$(( ${PA:-0} + 1 ))
  NEW_VER="${MA:-1}.${MI:-0}.${PA}"
fi
NEW_BUILD=$(( CUR_BUILD + 1 ))

echo "==> バージョン $CUR_VER (build $CUR_BUILD) -> $NEW_VER (build $NEW_BUILD)"

# --- 2. project.yml のバージョンを書き換え（app / share extension 両方）---
sed -i '' -E "s/(CFBundleShortVersionString: )\"[0-9.]+\"/\1\"$NEW_VER\"/g" project.yml
sed -i '' -E "s/(CFBundleVersion: )\"[0-9]+\"/\1\"$NEW_BUILD\"/g" project.yml

# --- 3. ビルド ---
scripts/build-ipa.sh

if [ ! -f "$IPA" ]; then
  echo "エラー: $IPA が生成されませんでした" >&2
  exit 1
fi

# --- 4. GitHub Release 作成 / .ipa アップロード ---
TAG="v$NEW_VER"
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$IPA" -R "$REPO" --clobber
else
  gh release create "$TAG" "$IPA" -R "$REPO" --title "$TAG" --notes "SNS Downloader $NEW_VER"
fi

DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/SNSDownloader.ipa"
SIZE=$(stat -f%z "$IPA")
DATE=$(date +%F)

# --- 5. apps.json 生成 ---
cp "$ICON_SRC" "$ICON"
cat > "$APPS_JSON" <<JSON
{
  "name": "SNS Downloader",
  "identifier": "tech.karabiner.mochi.altsource",
  "apps": [
    {
      "name": "SNS Downloader",
      "bundleIdentifier": "tech.karabiner.mochi.snsdownloader",
      "developerName": "TomPenguin",
      "subtitle": "SNSの画像・動画を写真に一括保存",
      "localizedDescription": "X / Instagram / TikTok / YouTube / pixiv の画像・動画・うごイラを写真ライブラリに保存します。",
      "iconURL": "https://raw.githubusercontent.com/$REPO/main/$ICON",
      "tintColor": "#1DA1F2",
      "category": "utilities",
      "versions": [
        {
          "version": "$NEW_VER",
          "buildVersion": "$NEW_BUILD",
          "date": "$DATE",
          "localizedDescription": "最新版",
          "downloadURL": "$DOWNLOAD_URL",
          "size": $SIZE,
          "minOSVersion": "16.0"
        }
      ],
      "appPermissions": {
        "entitlements": [],
        "privacy": {
          "NSPhotoLibraryAddUsageDescription": "ダウンロードした画像・動画を写真ライブラリに保存するため"
        }
      }
    }
  ],
  "news": []
}
JSON

# --- 6. apps.json / icon.png / project.yml をコミット & push ---
git add "$APPS_JSON" "$ICON" project.yml
git commit -m "Publish $NEW_VER (build $NEW_BUILD)"
git push origin HEAD

echo ""
echo "===================================================================="
echo " 公開完了: $NEW_VER"
echo " AltStore ソースURL:"
echo "   https://raw.githubusercontent.com/$REPO/main/$APPS_JSON"
echo "===================================================================="
echo " iPhone 側は AltStore がこのソースから自動で更新を検知します。"
