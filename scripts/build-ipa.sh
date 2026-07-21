#!/usr/bin/env bash
#
# AltStore / SideStore 用の未署名 .ipa を書き出す。
#
# 署名は AltStore/SideStore が「あなたの Apple ID」で入れるときに行うので、
# ここではビルド時に一切署名しない(CODE_SIGNING_ALLOWED=NO)。
# これにより証明書・プロビジョニングの設定なしで .ipa を作れる。
#
# 使い方:
#   scripts/build-ipa.sh
# 生成物:
#   dist/SNSDownloader.ipa   ← これを AltStore/SideStore に読み込ませる
#
set -euo pipefail

# リポジトリルートへ移動(このスクリプトの1つ上の階層)
cd "$(dirname "$0")/.."

PROJECT="SNSDownloader.xcodeproj"
SCHEME="SNSDownloader"
CONFIG="Release"
DERIVED="build"
DIST="dist"
IPA_NAME="SNSDownloader.ipa"

echo "==> xcodegen generate"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "エラー: xcodegen が見つかりません。'brew install xcodegen' を実行してください。" >&2
  exit 1
fi
xcodegen generate

echo "==> 未署名ビルド (CODE_SIGNING_ALLOWED=NO)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -sdk iphoneos \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  clean build

APP_PATH="$DERIVED/Build/Products/${CONFIG}-iphoneos/${SCHEME}.app"
if [ ! -d "$APP_PATH" ]; then
  echo "エラー: ビルド成果物が見つかりません: $APP_PATH" >&2
  exit 1
fi

echo "==> .ipa へパッケージ"
# .ipa は Payload/ 配下に .app を入れた zip
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP_PATH" "$STAGE/Payload/"

mkdir -p "$DIST"
rm -f "$DIST/$IPA_NAME"
( cd "$STAGE" && zip -qr "$IPA_NAME" Payload )
mv "$STAGE/$IPA_NAME" "$DIST/$IPA_NAME"

echo ""
echo "完成: $DIST/$IPA_NAME"
echo "  → この .ipa を AltStore/SideStore に読み込ませてください。"
echo "  → 署名は AltStore/SideStore があなたの Apple ID で行い、期限前に自動リフレッシュします。"
