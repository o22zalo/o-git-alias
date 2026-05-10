#!/usr/bin/env bash
# =============================================================================
# modules/odeletebranch.sh — Liệt kê branch từ tất cả remote, cho chọn và xóa
#
# Được load tự động bởi alias.sh — KHÔNG source trực tiếp file này
#
# Phụ thuộc (inject từ alias.sh trước khi source):
#   _O_SCRIPT_DIR   — thư mục gốc của alias.sh
#   O_CONFIG_FILE   — đường dẫn đến .git-o-config
#   _o_resolve_auth — hàm resolve auth từ .git-o-config
#   _o_embed_token  — hàm nhúng token vào URL
#
# Flow:
#   1. Thu thập tất cả o.url + o.url0..o.url9 từ .git/config
#   2. Dùng git ls-remote --heads để lấy danh sách branch từng remote
#      (không tạo remote tạm, không cần fetch)
#   3. Lọc bỏ protected branches: main, master, và branch hiện tại
#   4. Hiển thị danh sách — cùng branch trên nhiều remote sẽ hiển thị nhiều dòng
#   5. Cho chọn một hoặc nhiều branch (nhập số, cách nhau bằng dấu phẩy)
#   6. Xác nhận rồi xóa bằng git push --delete
# =============================================================================

[[ -n "${_O_MODULE_ODELETEBRANCH_LOADED:-}" ]] && return 0
_O_MODULE_ODELETEBRANCH_LOADED=1

# ---------------------------------------------------------------------------
# HELPER: Lấy danh sách branch từ remote URL qua ls-remote
# Không tạo remote tạm — gọi thẳng với auth URL / extraHeader
#
# Output stdout: mỗi dòng là một branch name
# ---------------------------------------------------------------------------
function _odb_list_remote_branches() {
    local url="$1"
    _o_resolve_auth "$url"

    local raw_output
    case "$O_AUTH_TYPE" in
        token)
            local auth_url
            auth_url=$(_o_embed_token "$url" "$O_AUTH_TOKEN" "$O_AUTH_USER")
            raw_output=$(git ls-remote --heads "$auth_url" 2>/dev/null) || true
            ;;
        header)
            raw_output=$(git -c "http.extraHeader=${O_AUTH_HEADER}" \
                ls-remote --heads "$url" 2>/dev/null) || true
            ;;
        none|*)
            raw_output=$(git ls-remote --heads "$url" 2>/dev/null) || true
            ;;
    esac

    [[ -z "$raw_output" ]] && return 0

    # Mỗi dòng ls-remote: "<sha>\trefs/heads/<branch>"
    while IFS=$'\t' read -r _sha ref; do
        local bname="${ref#refs/heads/}"
        [[ -n "$bname" && "$bname" != "$ref" ]] && printf '%s\n' "$bname"
    done <<< "$raw_output"
}

# ---------------------------------------------------------------------------
# HELPER: Xóa một branch trên remote URL
# Return: 0 = thành công, 1 = thất bại
# ---------------------------------------------------------------------------
function _odb_delete_remote_branch() {
    local url="$1"
    local branch="$2"
    _o_resolve_auth "$url"

    case "$O_AUTH_TYPE" in
        token)
            local auth_url
            auth_url=$(_o_embed_token "$url" "$O_AUTH_TOKEN" "$O_AUTH_USER")
            git push --quiet "$auth_url" --delete "$branch" 2>/dev/null
            ;;
        header)
            git -c "http.extraHeader=${O_AUTH_HEADER}" \
                push --quiet "$url" --delete "$branch" 2>/dev/null
            ;;
        none|*)
            git push --quiet "$url" --delete "$branch" 2>/dev/null
            ;;
    esac
}

# ---------------------------------------------------------------------------
# HELPER: Kiểm tra branch có nằm trong danh sách protected không
# Return: 0 = protected, 1 = không protected
# ---------------------------------------------------------------------------
function _odb_is_protected() {
    local bname="$1"
    shift
    local p
    for p in "$@"; do
        [[ "$bname" == "$p" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# HELPER: Parse chuỗi số cách phẩy, trả về mảng các số đã validate
# $1 = chuỗi input (vd "1,3,5")
# $2 = max value
# Output stdout: mỗi dòng một số hợp lệ
# Return: 0 = hợp lệ, 1 = có lỗi
# ---------------------------------------------------------------------------
function _odb_parse_selection() {
    local input="$1"
    local max="$2"
    local -a result=()

    IFS=',' read -ra parts <<< "$input"
    for part in "${parts[@]}"; do
        local num="${part// /}"        # trim spaces
        if ! [[ "$num" =~ ^[0-9]+$ ]]; then
            echo "[odeletebranch] Giá trị không hợp lệ: '$num'" >&2
            return 1
        fi
        if (( num < 1 || num > max )); then
            echo "[odeletebranch] Số ngoài phạm vi (1-${max}): $num" >&2
            return 1
        fi
        result+=("$num")
    done

    # Loại duplicate
    local seen="" n
    for n in "${result[@]}"; do
        if [[ ! " $seen " =~ " $n " ]]; then
            echo "$n"
            seen+=" $n"
        fi
    done
    return 0
}

# =============================================================================
# PUBLIC: odeletebranch
# =============================================================================
function odeletebranch() {

    if ! git rev-parse --git-dir &>/dev/null 2>&1; then
        echo "[odeletebranch] ERROR: Không phải git repo." >&2
        return 1
    fi

    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")

    # ── Protected branches (không cho xóa) ───────────────────────────────────
    # Lấy thêm từ git config o.protected (tuỳ chọn, cách nhau bằng dấu phẩy)
    local -a protected_branches=("main" "master" "$current_branch")

    local extra_protected
    extra_protected=$(git config --get o.protected 2>/dev/null || true)
    if [[ -n "$extra_protected" ]]; then
        IFS=',' read -ra extra_arr <<< "$extra_protected"
        local ep
        for ep in "${extra_arr[@]}"; do
            ep="${ep// /}"
            [[ -n "$ep" ]] && protected_branches+=("$ep")
        done
    fi

    # ── Thu thập URL ──────────────────────────────────────────────────────────
    local -a all_url_keys=()
    local -a all_url_vals=()

    local main_url
    main_url=$(git config --get o.url 2>/dev/null || true)
    [[ -n "$main_url" ]] && all_url_keys+=("o.url") && all_url_vals+=("$main_url")

    local i extra_url
    for i in $(seq 0 9); do
        extra_url=$(git config --get "o.url${i}" 2>/dev/null || true)
        [[ -n "$extra_url" ]] && all_url_keys+=("o.url${i}") && all_url_vals+=("$extra_url")
    done

    if [[ ${#all_url_vals[@]} -eq 0 ]]; then
        echo "[odeletebranch] ERROR: Không tìm thấy o.url nào trong .git/config." >&2
        echo "[odeletebranch]   Thiết lập: git config o.url https://github.com/org/repo.git" >&2
        return 1
    fi

    # ── Header ────────────────────────────────────────────────────────────────
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────"
    echo "  │  git odeletebranch"
    printf "  │  Branch hiện tại : %s  (được bảo vệ)\n" "$current_branch"
    printf "  │  Protected       : %s\n" "${protected_branches[*]}"
    printf "  │  Đang lấy branch từ %d remote(s)...\n" "${#all_url_vals[@]}"
    echo "  └─────────────────────────────────────────────────────────────"
    echo ""

    # ── Lấy danh sách branch từ từng remote ──────────────────────────────────
    local -a item_branch=()
    local -a item_url_key=()
    local -a item_url_val=()

    for ri in "${!all_url_vals[@]}"; do
        local key="${all_url_keys[$ri]}"
        local url="${all_url_vals[$ri]}"

        printf "  [list] %-10s  %s ... " "$key" "$url"

        local branches_raw
        branches_raw=$(_odb_list_remote_branches "$url")

        if [[ -z "$branches_raw" ]]; then
            echo "✗ thất bại hoặc không có branch"
            continue
        fi

        local count=0
        local skipped=0
        while IFS= read -r bname; do
            [[ -z "$bname" ]] && continue

            # Bỏ qua protected
            if _odb_is_protected "$bname" "${protected_branches[@]}"; then
                (( skipped++ )) || true
                continue
            fi

            item_branch+=("$bname")
            item_url_key+=("$key")
            item_url_val+=("$url")
            (( count++ )) || true
        done <<< "$branches_raw"

        if (( skipped > 0 )); then
            echo "✓ ($count branch(es), bỏ qua $skipped protected)"
        else
            echo "✓ ($count branch(es))"
        fi
    done

    echo ""

    # ── Không có branch nào để xóa ───────────────────────────────────────────
    if [[ ${#item_branch[@]} -eq 0 ]]; then
        echo "  ✓ Không có branch nào có thể xóa."
        echo "    (main, master và branch hiện tại được bảo vệ tự động)"
        echo ""
        echo "  Thêm protected branch tùy chỉnh:"
        echo "    git config o.protected develop,staging"
        echo ""
        return 0
    fi

    # ── Hiển thị danh sách ────────────────────────────────────────────────────
    echo "  Branch có thể xóa:"
    echo ""
    printf "    %-4s  %-36s  %s\n" "#" "Branch" "Remote"
    echo "    ────  ────────────────────────────────────  ──────────"

    local j
    for j in "${!item_branch[@]}"; do
        printf "    [%d]  %-36s  %s\n" \
            "$((j + 1))" \
            "${item_branch[$j]}" \
            "${item_url_key[$j]}"
    done

    local max="${#item_branch[@]}"

    echo ""
    echo "    [0]  Hủy"
    echo ""
    echo "  Gõ số thứ tự muốn xóa, nhiều branch cách nhau bằng dấu phẩy."
    echo "  Ví dụ: 1       → xóa branch số 1"
    echo "         1,3,5   → xóa branch số 1, 3 và 5"
    echo ""

    # ── Nhập lựa chọn ────────────────────────────────────────────────────────
    local choice
    local -a selected_nums=()

    while true; do
        read -r -p "  Chọn branch để xóa [0-${max}]: " choice
        [[ "$choice" == "0" ]] && { echo "  Hủy."; echo ""; return 0; }

        local parsed_nums
        if parsed_nums=$(_odb_parse_selection "$choice" "$max"); then
            mapfile -t selected_nums <<< "$parsed_nums"
            [[ ${#selected_nums[@]} -gt 0 ]] && break
        fi
        echo "  Nhập số từ 1 đến ${max} (hoặc nhiều số cách nhau bằng dấu phẩy). Nhập 0 để hủy."
    done

    # ── Tổng hợp danh sách sẽ xóa ────────────────────────────────────────────
    local -a to_delete_branch=()
    local -a to_delete_key=()
    local -a to_delete_url=()

    local num
    for num in "${selected_nums[@]}"; do
        local idx=$(( num - 1 ))
        to_delete_branch+=("${item_branch[$idx]}")
        to_delete_key+=("${item_url_key[$idx]}")
        to_delete_url+=("${item_url_val[$idx]}")
    done

    # ── Xác nhận ──────────────────────────────────────────────────────────────
    echo ""
    echo "  Sắp xóa các branch sau:"
    echo ""
    local k
    for k in "${!to_delete_branch[@]}"; do
        printf "    ✗  %-36s  trên %s\n" \
            "${to_delete_branch[$k]}" \
            "${to_delete_key[$k]}"
    done
    echo ""
    echo "  ⚠  Hành động này KHÔNG THỂ hoàn tác!"
    echo ""

    local confirm
    read -r -p "  Xác nhận xóa? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "  Hủy."
        echo ""
        return 0
    fi

    # ── Thực hiện xóa ─────────────────────────────────────────────────────────
    echo ""
    local has_error=0

    for k in "${!to_delete_branch[@]}"; do
        local bname="${to_delete_branch[$k]}"
        local ukey="${to_delete_key[$k]}"
        local uval="${to_delete_url[$k]}"

        printf "  [delete] %-36s  %s ... " "$bname" "$ukey"

        if _odb_delete_remote_branch "$uval" "$bname"; then
            echo "✓"
        else
            echo "✗ thất bại"
            has_error=1
        fi
    done

    echo ""
    if (( has_error )); then
        echo "  ⚠  Một số branch xóa thất bại."
        echo "     Kiểm tra quyền truy cập remote (token cần quyền delete branch)."
    else
        local del_count="${#to_delete_branch[@]}"
        echo "  ✓ Đã xóa thành công ${del_count} branch(es)."
    fi

    echo ""
    echo "  [odeletebranch] Done."
    echo ""
}