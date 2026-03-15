#!/bin/bash
# build_and_download.sh — ビルド→DL→フラッシュ一括実行
# 使い方:
#   ./scripts/build_and_download.sh "コミットメッセージ"          → ビルド＆DLのみ
#   ./scripts/build_and_download.sh "コミットメッセージ" --flash  → ビルド＆DL＆フラッシュ(quick)
#   ./scripts/build_and_download.sh "コミットメッセージ" --full   → ビルド＆DL＆フルリセット

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIRMWARE_DIR="$REPO_DIR/firmware/firmware"
SCRIPT_DIR="$REPO_DIR/scripts"
cd "$REPO_DIR"

# ── 引数解析 ──
MSG="${1:-Update keymap}"
FLASH_MODE="${2:-}"

# ── 色定義 ──
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── 変更チェック ──
if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    echo "⚠ 変更なし。.keymap を編集してから実行してください。"
    exit 1
fi

# ── ステージ・コミット・プッシュ ──
echo -e "${CYAN}📦${NC} コミット: $MSG"
git add -A
git commit -m "$MSG"
git push

# ── ビルド待ち ──
echo -e "${CYAN}⏳${NC} GitHub Actions ビルド開始を待っています..."
sleep 5

RUN_ID=$(gh run list --event push --branch main --limit 1 --json databaseId --jq '.[0].databaseId')
if [ -z "$RUN_ID" ]; then
    echo "❌ ビルド run が見つかりません"
    exit 1
fi

REPO_URL="https://github.com/$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
echo -e "${CYAN}🔨${NC} ビルド実行中 (Run ID: $RUN_ID)"
echo "   $REPO_URL/actions/runs/$RUN_ID"

gh run watch "$RUN_ID" --exit-status
echo -e "${GREEN}✅${NC} ビルド成功！"

# ── ファームウェアDL ──
rm -rf "$FIRMWARE_DIR"
mkdir -p "$FIRMWARE_DIR"
echo -e "${CYAN}📥${NC} ファームウェアをダウンロード中..."
gh run download "$RUN_ID" -n firmware -D "$(dirname "$FIRMWARE_DIR")"

echo ""
echo -e "${GREEN}✅${NC} ダウンロード完了"
ls -1 "$FIRMWARE_DIR"/*.uf2 2>/dev/null | while read -r f; do
    echo "   $(basename "$f")"
done

# ── フラッシュ ──
case "$FLASH_MODE" in
    --flash)
        echo ""
        bash "$SCRIPT_DIR/flash.sh" quick
        ;;
    --full)
        echo ""
        bash "$SCRIPT_DIR/flash.sh" full
        ;;
    "")
        echo ""
        echo -e "${BOLD}━━━ フラッシュするには ━━━${NC}"
        echo "  bash scripts/flash.sh quick   # ファームウェアのみ"
        echo "  bash scripts/flash.sh full    # フルリセット＋再ペアリング"
        echo "  bash scripts/flash.sh right   # 右手のみ"
        echo "  bash scripts/flash.sh left    # 左手のみ"
        ;;
esac
