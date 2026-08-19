#!/usr/bin/env bash
# =============================================================================
# modules/opullmanual.sh — Chọn remote URL rồi pull về
# Được load tự động bởi alias.sh — KHÔNG source trực tiếp file này
#
# Phụ thuộc (inject từ alias.sh trước khi source):
#   _O_SCRIPT_DIR        — thư mục gốc của alias.sh
#   O_CONFIG_FILE        — đường dẫn đến .git-o-config
#   _o_resolve_auth      — hàm resolve auth từ .git-o-config
#   _o_embed_token       — hàm nhúng token vào URL
#   _o_run_git           — hàm chạy git command với auth tự động
#
# Flow:
#   1. Thu thập tất cả o.url + o.url0..o.url9 từ .git/config
#   2. Hiển thị menu chọn URL (single-select)
#   3. Thực hiện git pull từ URL đã chọn
# =============================================================================

[[ -n "${_O_MODULE_OPULLMANUAL_LOADED:-}" ]] && return 0
_O_MODULE_OPULLMANUAL_LOADED=1

# =============================================================================
# PUBLIC: opullmanual — chọn remote URL rồi pull
#
# Cú pháp: git opullmanual [git_pull_args...]
#          git oplm        [git_pull_args...]
# =============================================================================
function opullmanual() {

    # ── Kiểm tra môi trường ───────────────────────────────────────────────────
    if ! git rev-parse --git-dir &>/dev/null 2>&1; then
        echo "[opullmanual] ERROR: Không phải git repo." >&2
        return 1
    fi

    # ── Thu thập danh sách URL ────────────────────────────────────────────────
    local -a url_keys=()
    local -a url_vals=()

    local main_url
    main_url=$(git config --get o.url 2>/dev/null || true)
    if [[ -n "$main_url" ]]; then
        url_keys+=("o.url")
        url_vals+=("$main_url")
    fi

    local i extra_url
    for i in $(seq 0 9); do
        extra_url=$(git config --get "o.url${i}" 2>/dev/null || true)
        if [[ -n "$extra_url" ]]; then
            url_keys+=("o.url${i}")
            url_vals+=("$extra_url")
        fi
    done

    if [[ ${#url_vals[@]} -eq 0 ]]; then
        echo "[opullmanual] ERROR: Không tìm thấy o.url nào trong .git/config." >&2
        echo "[opullmanual]   Thiết lập remote:" >&2
        echo "[opullmanual]   git config o.url  https://github.com/org/repo.git" >&2
        echo "[opullmanual]   git config o.url0 https://gitlab.com/org/repo.git" >&2
        return 1
    fi

    # ── Hiển thị menu chọn URL ────────────────────────────────────────────────
    echo ""
    echo "  ┌─────────────────────────────────────────────────"
    echo "  │  git opullmanual"
    echo "  ├─────────────────────────────────────────────────"
    echo "  │  Chọn remote URL để pull về"
    echo "  └─────────────────────────────────────────────────"
    echo ""
    echo "  Chọn remote URL để pull:"
    echo ""

    local j
    for j in "${!url_vals[@]}"; do
        printf "    [%d] %-12s  %s\n" "$((j+1))" "${url_keys[$j]}" "${url_vals[$j]}"
    done
    echo ""

    local choice
    while true; do
        read -r -p "  Số thứ tự [1-${#url_vals[@]}]: " choice
        [[ "$choice" =~ ^[0-9]+$ ]] \
            && (( choice >= 1 && choice <= ${#url_vals[@]} )) \
            && break
        echo "  Nhập số từ 1 đến ${#url_vals[@]}."
    done

    local selected_key="${url_keys[$((choice-1))]}"
    local selected_url="${url_vals[$((choice-1))]}"

    echo ""
    echo "  → Remote : $selected_key  →  $selected_url"
    echo "  [opullmanual] Đang pull từ $selected_url ..."
    echo ""

    # ── Thực hiện pull từ URL đã chọn ─────────────────────────────────────────
    _o_run_git "$selected_url" pull "$@"
}
