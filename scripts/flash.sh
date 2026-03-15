#!/bin/bash
# flash.sh — Keyball BLE ファームウェアフラッシュ自動化
# 使い方:
#   ./scripts/flash.sh          → フルリセット（settings_reset + L/R + BT再接続）
#   ./scripts/flash.sh quick    → ファームウェアのみ（R + L）
#   ./scripts/flash.sh reset    → settings_reset のみ（左右）
#   ./scripts/flash.sh right    → 右手のみ
#   ./scripts/flash.sh left     → 左手のみ

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FW_DIR="$REPO_DIR/firmware/firmware"
MOUNT_POINT="/Volumes/XIAO-SENSE"
BT_DEVICE_NAME="KeyballBLE"

# ── 色定義 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── ファームウェアファイル ──
FW_RESET="$FW_DIR/settings_reset-seeeduino_xiao_ble-zmk.uf2"
FW_R=$(ls "$FW_DIR"/*KeyballBLE_R* 2>/dev/null | head -1 || true)
FW_L=$(ls "$FW_DIR"/*KeyballBLE_L* 2>/dev/null | head -1 || true)

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# ユーティリティ関数
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

say() { echo -e "${CYAN}▶${NC} $1"; }
ok()  { echo -e "${GREEN}✅${NC} $1"; }
warn(){ echo -e "${YELLOW}⚠${NC} $1"; }
err() { echo -e "${RED}❌${NC} $1"; exit 1; }

# XIAO-SENSE マウント待ち
wait_for_mount() {
    if [ -d "$MOUNT_POINT" ]; then
        return 0
    fi
    echo ""
    echo -e "${BOLD}━━━ リセットボタンを素早く2回押してください ━━━${NC}"
    echo -e "    （XIAO-SENSE がマウントされるのを待機中...）"
    while [ ! -d "$MOUNT_POINT" ]; do
        sleep 0.3
    done
    sleep 0.5  # マウント安定待ち
    ok "XIAO-SENSE 検出"
}

# ファームウェアをコピーしてアンマウント待ち
flash_uf2() {
    local uf2_file="$1"
    local label="$2"
    local basename=$(basename "$uf2_file")

    if [ ! -f "$uf2_file" ]; then
        err "$label のファームウェアが見つかりません: $uf2_file"
    fi

    say "$label をフラッシュ中: ${basename}"
    cp "$uf2_file" "$MOUNT_POINT/" 2>/dev/null || true  # extended attributes エラーは無視

    # アンマウント待ち（自動リブート検知）
    local count=0
    while [ -d "$MOUNT_POINT" ]; do
        sleep 0.3
        count=$((count + 1))
        if [ $count -gt 100 ]; then  # 30秒タイムアウト
            warn "タイムアウト — XIAO-SENSE がまだマウントされています"
            return 1
        fi
    done
    ok "$label フラッシュ完了"
    sleep 1  # リブート安定待ち
}

# Mac側 Bluetooth クリーンアップ
bt_cleanup() {
    say "Mac 側 Bluetooth をクリーンアップ中..."

    # blueutil でデバイスを検索・削除
    if command -v blueutil &>/dev/null; then
        # ペアリング済みデバイスから KeyballBLE を探して削除
        local devices
        devices=$(blueutil --paired --format json 2>/dev/null || echo "[]")
        local addrs
        addrs=$(echo "$devices" | python3 -c "
import sys, json
devs = json.load(sys.stdin)
for d in devs:
    if '$BT_DEVICE_NAME' in d.get('name', ''):
        print(d['address'])
" 2>/dev/null || true)

        if [ -n "$addrs" ]; then
            while IFS= read -r addr; do
                say "BT デバイス削除: $addr"
                blueutil --unpair "$addr" 2>/dev/null || true
            done <<< "$addrs"
            ok "KeyballBLE のペアリング情報を削除"
        else
            warn "ペアリング済みの KeyballBLE が見つかりませんでした（すでに削除済みかも）"
        fi
    else
        warn "blueutil がインストールされていません（brew install blueutil）"
        warn "システム環境設定 → Bluetooth から手動で KeyballBLE を削除してください"
    fi

    # bluetoothd 再起動
    say "bluetoothd を再起動中..."
    sudo pkill bluetoothd 2>/dev/null || true
    sleep 2
    ok "Bluetooth サービス再起動完了"
}

# ペアリング待ち
wait_for_pairing() {
    echo ""
    echo -e "${BOLD}━━━ 再ペアリング ━━━${NC}"
    echo "  1. キーボードの電源を入れる（USB を抜いた状態）"
    echo "  2. Mac の Bluetooth 設定で KeyballBLE を探す"
    echo "  3. 「接続」をクリック"
    echo ""

    if command -v blueutil &>/dev/null; then
        say "KeyballBLE の検出を待機中..."
        local attempts=0
        while [ $attempts -lt 60 ]; do
            local found
            found=$(blueutil --inquiry 2 2>/dev/null | grep -i "$BT_DEVICE_NAME" || true)
            if [ -n "$found" ]; then
                ok "KeyballBLE を検出しました！"
                echo -e "    システム環境設定 → Bluetooth で「接続」してください"
                break
            fi
            attempts=$((attempts + 1))
        done
        if [ $attempts -ge 60 ]; then
            warn "タイムアウト — 手動でペアリングしてください"
        fi
    else
        echo "  ※ Enter を押して続行..."
        read -r
    fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# メインフロー
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

MODE="${1:-full}"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Keyball BLE ファームウェアフラッシュ${NC}"
echo -e "${BOLD}  モード: ${CYAN}${MODE}${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ファームウェアの存在チェック
if [ ! -d "$FW_DIR" ]; then
    err "ファームウェアが見つかりません。先に build_and_download.sh を実行してください。"
fi

case "$MODE" in
    full)
        # ── Step 1: 右手 settings_reset ──
        echo -e "${BOLD}[1/6] 右手 settings_reset${NC}"
        say "右手を USB-C で接続してください"
        wait_for_mount
        flash_uf2 "$FW_RESET" "右手 settings_reset"

        # ── Step 2: 左手 settings_reset ──
        echo ""
        echo -e "${BOLD}[2/6] 左手 settings_reset${NC}"
        say "左手を USB-C で接続してください"
        wait_for_mount
        flash_uf2 "$FW_RESET" "左手 settings_reset"

        # ── Step 3: BT クリーンアップ ──
        echo ""
        echo -e "${BOLD}[3/6] Bluetooth クリーンアップ${NC}"
        bt_cleanup

        # ── Step 4: 右手ファームウェア ──
        echo ""
        echo -e "${BOLD}[4/6] 右手ファームウェア${NC}"
        say "右手を USB-C で接続してください"
        wait_for_mount
        flash_uf2 "$FW_R" "右手 KeyballBLE_R"

        # ── Step 5: 左手ファームウェア ──
        echo ""
        echo -e "${BOLD}[5/6] 左手ファームウェア${NC}"
        say "左手を USB-C で接続してください"
        wait_for_mount
        flash_uf2 "$FW_L" "左手 KeyballBLE_L"

        # ── Step 6: 再ペアリング ──
        echo ""
        echo -e "${BOLD}[6/6] 再ペアリング${NC}"
        wait_for_pairing

        echo ""
        ok "フルリセット＆フラッシュ完了！"
        ;;

    quick)
        # ── 右手ファームウェア ──
        echo -e "${BOLD}[1/2] 右手ファームウェア${NC}"
        say "右手を USB-C で接続してください"
        wait_for_mount
        flash_uf2 "$FW_R" "右手 KeyballBLE_R"

        # ── 左手ファームウェア ──
        echo ""
        echo -e "${BOLD}[2/2] 左手ファームウェア${NC}"
        say "左手を USB-C で接続してください"
        wait_for_mount
        flash_uf2 "$FW_L" "左手 KeyballBLE_L"

        echo ""
        ok "ファームウェアフラッシュ完了！"
        ;;

    reset)
        # ── 右手 settings_reset ──
        echo -e "${BOLD}[1/3] 右手 settings_reset${NC}"
        say "右手を USB-C で接続してください"
        wait_for_mount
        flash_uf2 "$FW_RESET" "右手 settings_reset"

        # ── 左手 settings_reset ──
        echo ""
        echo -e "${BOLD}[2/3] 左手 settings_reset${NC}"
        say "左手を USB-C で接続してください"
        wait_for_mount
        flash_uf2 "$FW_RESET" "左手 settings_reset"

        # ── BT クリーンアップ ──
        echo ""
        echo -e "${BOLD}[3/3] Bluetooth クリーンアップ${NC}"
        bt_cleanup

        echo ""
        ok "settings_reset 完了！"
        ;;

    right)
        say "右手を USB-C で接続してください"
        wait_for_mount
        flash_uf2 "$FW_R" "右手 KeyballBLE_R"
        ok "右手フラッシュ完了！"
        ;;

    left)
        say "左手を USB-C で接続してください"
        wait_for_mount
        flash_uf2 "$FW_L" "左手 KeyballBLE_L"
        ok "左手フラッシュ完了！"
        ;;

    *)
        echo "使い方: $0 [full|quick|reset|right|left]"
        echo "  full  : settings_reset(左右) + BT再接続 + ファームウェア(左右) + 再ペアリング"
        echo "  quick : ファームウェアのみ(右→左)"
        echo "  reset : settings_reset のみ(右→左) + BTクリーンアップ"
        echo "  right : 右手ファームウェアのみ"
        echo "  left  : 左手ファームウェアのみ"
        exit 1
        ;;
esac
