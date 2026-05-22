#!/usr/bin/env bash
# =============================================================================
# modules/oaddconfig.sh — Thêm GitHub token vào .git-o-config (interactive)
# Được load tự động bởi alias.sh — KHÔNG source trực tiếp file này
#
# Phụ thuộc (inject từ alias.sh trước khi source):
#   O_CONFIG_FILE   — đường dẫn đến .git-o-config
#
# Flow:
#   1. Nhập GitHub Personal Access Token (ẩn khi gõ)
#   2. Verify token qua API → lấy username
#   3. Fetch danh sách: bản thân (username) + tất cả org user thuộc về
#   4. Hiện menu chọn org/account để gắn token
#   5. Confirm → ghi [github.com/<owner>] + token= vào .git-o-config
# =============================================================================

[[ -n "${_O_MODULE_ADDCONFIG_LOADED:-}" ]] && return 0
_O_MODULE_ADDCONFIG_LOADED=1

# ---------------------------------------------------------------------------
# HELPER: Gọi GitHub API với Bearer token
# $1 = path (ví dụ: /user/orgs)
# $2 = token
# ---------------------------------------------------------------------------
function _oac_gh_api() {
    local path="$1" token="$2"
    curl -s \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com${path}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# HELPER: Trích một field string đơn giản từ JSON (không nested)
# $1 = field name, $2 = json string
# ---------------------------------------------------------------------------
function _oac_json_field() {
    local field="$1" json="$2"
    echo "$json" \
        | grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -1 \
        | cut -d'"' -f4
}

# ---------------------------------------------------------------------------
# HELPER: Trích danh sách "login" từ JSON mảng orgs/users của GitHub
# Output: mỗi dòng một login name
# ---------------------------------------------------------------------------
function _oac_parse_login_list() {
    local json="$1"
    echo "$json" \
        | grep -oE '"login"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | cut -d'"' -f4
}

# ---------------------------------------------------------------------------
# HELPER: Kiểm tra section đã tồn tại trong config chưa
# $1 = section key (không kèm [])
# Return 0 nếu tồn tại, 1 nếu không
# ---------------------------------------------------------------------------
function _oac_section_exists() {
    local section="$1"
    [[ -f "$O_CONFIG_FILE" ]] \
        && grep -qxF "[${section}]" "$O_CONFIG_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# HELPER: Xóa một section khỏi config (cả key bên dưới, đến section tiếp theo)
# $1 = section key (không kèm [])
# ---------------------------------------------------------------------------
function _oac_remove_section() {
    local section="$1"
    local tmpfile
    tmpfile=$(mktemp "/tmp/git-o-config.XXXXXX")
    local in_section=0

    while IFS= read -r raw || [[ -n "$raw" ]]; do
        local line="${raw%%$'\r'}"
        local line_trim="${line#"${line%%[![:space:]]*}"}"
        if [[ "$line_trim" =~ ^\[(.+)\]$ ]]; then
            if [[ "${BASH_REMATCH[1]}" == "$section" ]]; then
                in_section=1
                continue
            else
                in_section=0
            fi
        fi
        [[ "$in_section" == "0" ]] && printf '%s\n' "$raw" >> "$tmpfile"
    done < "$O_CONFIG_FILE"

    mv "$tmpfile" "$O_CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# HELPER: Ghi section + token vào cuối .git-o-config
# $1 = section key (ví dụ: github.com/myorg)
# $2 = token
# ---------------------------------------------------------------------------
function _oac_write_section() {
    local section="$1" token="$2"

    # Tạo file nếu chưa có
    if [[ ! -f "$O_CONFIG_FILE" ]]; then
        {
            echo "# .git-o-config — Tạo tự động bởi git oaddconfig"
            echo "# KHÔNG commit file này lên git"
        } > "$O_CONFIG_FILE"
    fi

    # Thêm dòng trống ngăn cách nếu file không rỗng
    local last_char
    last_char=$(tail -c1 "$O_CONFIG_FILE" 2>/dev/null | wc -c)
    (( last_char > 0 )) && echo "" >> "$O_CONFIG_FILE"

    {
        echo "[${section}]"
        echo "token=${token}"
    } >> "$O_CONFIG_FILE"
}

# =============================================================================
# PUBLIC: oaddconfig
#
# Cú pháp: git oaddconfig
#
# Wizard thêm GitHub token vào .git-o-config theo org/account.
# =============================================================================
function oaddconfig() {
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────"
    echo "  │  git oaddconfig — Thêm GitHub token vào .git-o-config"
    echo "  └─────────────────────────────────────────────────────────"
    echo ""

    # ─────────────────────────────────────────────────────────────────────────
    # BƯỚC 1 — Nhập token (ẩn khi gõ)
    # ─────────────────────────────────────────────────────────────────────────
    echo "  Tạo PAT tại: https://github.com/settings/tokens"
    echo "  Scope cần  : repo  (hoặc Fine-grained với quyền Contents + Metadata)"
    echo ""

    local token=""
    while true; do
        read -r -s -p "  GitHub Token: " token
        echo ""
        [[ -n "$token" ]] && break
        echo "  Token không được để trống."
    done

    # ─────────────────────────────────────────────────────────────────────────
    # BƯỚC 2 — Verify token → lấy username
    # ─────────────────────────────────────────────────────────────────────────
    echo ""
    echo "  Đang xác thực token..."

    local user_resp
    user_resp=$(_oac_gh_api "/user" "$token")

    local gh_login
    gh_login=$(_oac_json_field "login" "$user_resp")

    if [[ -z "$gh_login" ]]; then
        local err_msg
        err_msg=$(_oac_json_field "message" "$user_resp")
        echo ""
        echo "  ✗ Token không hợp lệ hoặc không có quyền." >&2
        [[ -n "$err_msg" ]] && echo "  ✗ Lỗi API: $err_msg" >&2
        return 1
    fi

    local gh_name
    gh_name=$(_oac_json_field "name" "$user_resp")
    echo "  ✓ Xác thực thành công: $gh_login${gh_name:+ ($gh_name)}"

    # ─────────────────────────────────────────────────────────────────────────
    # BƯỚC 3 — Fetch danh sách org user thuộc về
    # ─────────────────────────────────────────────────────────────────────────
    echo ""
    echo "  Đang tải danh sách org..."

    local orgs_resp
    orgs_resp=$(_oac_gh_api "/user/orgs?per_page=100" "$token")

    local -a org_list=()
    while IFS= read -r login; do
        [[ -n "$login" ]] && org_list+=("$login")
    done < <(_oac_parse_login_list "$orgs_resp")

    # ─────────────────────────────────────────────────────────────────────────
    # BƯỚC 4 — Hiện menu chọn: bản thân + các org
    # ─────────────────────────────────────────────────────────────────────────
    echo ""
    echo "  ┌──────────────────────────────────────────────────────────────"
    printf "  │  %4s  %-30s  %s\n" "#" "Owner / Org" "Section sẽ ghi"
    echo "  │  ────  ──────────────────────────────  ──────────────────────────────"
    printf "  │  %4d  %-30s  [github.com/%s]\n" "1" "$gh_login  ← tài khoản cá nhân" "$gh_login"

    local i
    for i in "${!org_list[@]}"; do
        local org="${org_list[$i]}"
        printf "  │  %4d  %-30s  [github.com/%s]\n" "$((i+2))" "$org" "$org"
    done

    echo "  └──────────────────────────────────────────────────────────────"
    echo ""

    local total=$(( ${#org_list[@]} + 1 ))
    local choice
    while true; do
        read -r -p "  Chọn số thứ tự [1-${total}] (Enter = 1): " choice
        choice="${choice:-1}"
        [[ "$choice" =~ ^[0-9]+$ ]] \
            && (( choice >= 1 && choice <= total )) \
            && break
        echo "  Nhập số từ 1 đến ${total}."
    done

    # Xác định owner được chọn
    local selected_owner
    if [[ "$choice" == "1" ]]; then
        selected_owner="$gh_login"
    else
        selected_owner="${org_list[$((choice-2))]}"
    fi

    local section_key="github.com/${selected_owner}"
    local token_preview="${token:0:8}***"

    # ─────────────────────────────────────────────────────────────────────────
    # BƯỚC 5 — Confirm + ghi vào config
    # ─────────────────────────────────────────────────────────────────────────
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────"
    echo "  │  Tóm tắt"
    echo "  ├─────────────────────────────────────────────────────────"
    printf "  │  Section : [%s]\n"  "$section_key"
    printf "  │  token   : %s\n"   "$token_preview"
    printf "  │  File    : %s\n"   "$O_CONFIG_FILE"
    echo "  └─────────────────────────────────────────────────────────"
    echo ""

    local confirm
    read -r -p "  Ghi vào .git-o-config? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    if [[ "${confirm,,}" != "y" ]]; then
        echo "  Hủy."
        return 0
    fi

    # Kiểm tra section đã tồn tại
    if _oac_section_exists "$section_key"; then
        echo ""
        echo "  ⚠ Section [$section_key] đã tồn tại trong config."
        local overwrite
        read -r -p "  Ghi đè token mới? [y/N]: " overwrite
        if [[ "${overwrite,,}" != "y" ]]; then
            echo "  Hủy — không thay đổi config."
            return 0
        fi
        _oac_remove_section "$section_key"
        echo "  ✓ Đã xóa section cũ."
    fi

    _oac_write_section "$section_key" "$token"

    echo ""
    echo "  ✓ Đã thêm vào $(basename "$O_CONFIG_FILE"):"
    echo "    [${section_key}]"
    echo "    token=${token_preview}"
    echo ""
    echo "  Dùng ngay:"
    echo "    git config o.url https://github.com/${selected_owner}/<repo>.git"
    echo "    git opush"
}