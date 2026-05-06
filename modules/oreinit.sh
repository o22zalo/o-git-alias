#!/usr/bin/env bash
# =============================================================================
# modules/oreinit.sh — Xóa toàn bộ git history, giữ .git/config, init lại repo
# Được load tự động bởi alias.sh — KHÔNG source trực tiếp file này
#
# Phụ thuộc (inject từ alias.sh trước khi source):
#   _O_SCRIPT_DIR   — thư mục gốc của alias.sh
#   O_CONFIG_FILE   — đường dẫn đến .git-o-config
#
# Flow:
#   1. Kiểm tra đang ở trong git repo
#   2. Hiển thị cảnh báo + xác nhận
#   3. Lưu .git/config vào file tạm
#   4. rm -rf .git
#   5. git init --initial-branch=main
#   6. Chép .git/config từ file tạm về
#   7. git add -A
#   8. git commit -m "<user_input hoặc ReInitGit-YYYYMMDD>"
# =============================================================================

[[ -n "${_O_MODULE_OREINIT_LOADED:-}" ]] && return 0
_O_MODULE_OREINIT_LOADED=1

# =============================================================================
# PUBLIC: oreinit — Xóa git history, giữ config, init repo mới
#
# Cú pháp: git oreinit [commit_message]
#          git ori     [commit_message]
# =============================================================================
function oreinit() {

    # ── Kiểm tra môi trường ───────────────────────────────────────────────────
    if ! git rev-parse --git-dir &>/dev/null 2>&1; then
        echo "[oreinit] ERROR: Không phải git repo." >&2
        echo "[oreinit]   Hãy chạy lệnh này trong thư mục chứa repo git." >&2
        return 1
    fi

    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

    local git_dir="${repo_root}/.git"

    if [[ ! -d "$git_dir" ]]; then
        echo "[oreinit] ERROR: Không tìm thấy thư mục .git tại: $git_dir" >&2
        return 1
    fi

    # ── Đếm số commit hiện tại ────────────────────────────────────────────────
    local commit_count="0"
    commit_count=$(git rev-list --count HEAD 2>/dev/null || echo "0")

    # ── Hiển thị cảnh báo ─────────────────────────────────────────────────────
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────"
    echo "  │  git oreinit — Xóa git history & init lại repo"
    echo "  ├─────────────────────────────────────────────────────────────"
    printf "  │  Repo     : %s\n" "$repo_root"
    printf "  │  Commits  : %s commit(s) hiện tại → sẽ bị XÓA VĨNH VIỄN\n" "$commit_count"
    echo "  │  Giữ lại  : .git/config  (remote URL, user, o.url)"
    echo "  │  Kết quả  : 1 commit mới duy nhất với toàn bộ file hiện tại"
    echo "  ├─────────────────────────────────────────────────────────────"
    echo "  │  ⚠  CẢNH BÁO: Thao tác này KHÔNG THỂ hoàn tác!"
    echo "  │     Toàn bộ lịch sử commit sẽ bị xóa vĩnh viễn."
    echo "  │     Nên dùng khi: repo quá nặng, chứa thông tin nhạy cảm,"
    echo "  │     hoặc muốn bắt đầu lại lịch sử sạch trước khi deploy."
    echo "  └─────────────────────────────────────────────────────────────"
    echo ""

    # ── Xác nhận ──────────────────────────────────────────────────────────────
    local confirm
    read -r -p "  Xác nhận xóa toàn bộ history? [y/N]: " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        echo "  Hủy."
        echo ""
        return 0
    fi

    # ── Commit message ────────────────────────────────────────────────────────
    local commit_msg=""
    if [[ -n "$*" ]]; then
        commit_msg="$*"
    else
        local default_msg
        default_msg="ReInitGit-$(date '+%Y%m%d')"
        echo ""
        read -r -p "  Commit message [${default_msg}]: " commit_msg
        commit_msg="${commit_msg:-$default_msg}"
    fi

    echo ""
    echo "  → Commit message: $commit_msg"
    echo ""

    # ── Lưu .git/config ───────────────────────────────────────────────────────
    local git_config_src="${git_dir}/config"
    local tmp_config
    tmp_config=$(mktemp "/tmp/git-o-reinit-config.XXXXXX")

    if [[ -f "$git_config_src" ]]; then
        cp "$git_config_src" "$tmp_config"
        echo "  [oreinit] ✓ Đã sao lưu .git/config → $tmp_config"
    else
        echo "  [oreinit] WARN: Không tìm thấy .git/config — sẽ init repo trần." >&2
        tmp_config=""
    fi

    # ── Xóa .git ──────────────────────────────────────────────────────────────
    echo "  [oreinit] Đang xóa .git ..."
    rm -rf "$git_dir"

    if [[ -d "$git_dir" ]]; then
        echo "  [oreinit] ERROR: Không thể xóa thư mục .git — kiểm tra quyền truy cập." >&2
        [[ -n "$tmp_config" ]] && rm -f "$tmp_config"
        return 1
    fi

    echo "  [oreinit] ✓ Đã xóa .git"

    # ── Init repo mới ─────────────────────────────────────────────────────────
    echo "  [oreinit] Đang init repo mới ..."
    if ! git -C "$repo_root" init --initial-branch=main 2>/dev/null; then
        # Fallback cho git phiên bản cũ không hỗ trợ --initial-branch
        git -C "$repo_root" init
        git -C "$repo_root" checkout -b main 2>/dev/null || true
    fi

    echo "  [oreinit] ✓ git init xong"

    # ── Chép lại .git/config ──────────────────────────────────────────────────
    if [[ -n "$tmp_config" && -f "$tmp_config" ]]; then
        cp "$tmp_config" "${git_dir}/config"
        rm -f "$tmp_config"
        echo "  [oreinit] ✓ Đã khôi phục .git/config"
    fi

    # ── Commit toàn bộ file hiện tại ─────────────────────────────────────────
    echo "  [oreinit] Đang staging toàn bộ file ..."
    git -C "$repo_root" add -A

    local staged_count
    staged_count=$(git -C "$repo_root" diff --cached --name-only 2>/dev/null | wc -l)
    echo "  [oreinit] → $staged_count file(s) sẽ được commit"

    echo "  [oreinit] Đang commit ..."
    git -C "$repo_root" commit -m "$commit_msg" --allow-empty

    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────"
    echo "  │  ✓ oreinit hoàn thành!"
    printf "  │  Commit : %s\n" "$commit_msg"
    printf "  │  Files  : %s file(s)\n" "$staged_count"
    echo "  │"
    echo "  │  Bước tiếp theo:"
    echo "  │    git opushforce   ← force push lên tất cả remote"
    echo "  │    git opushforceurl ← force push lên 1 remote cụ thể"
    echo "  └─────────────────────────────────────────────────────────────"
    echo ""
}
