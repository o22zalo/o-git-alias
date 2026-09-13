#!/usr/bin/env bash
# =============================================================================
# modules/ocloneall.sh — Clone hàng loạt repo của Org hoặc Cá nhân
# Được load tự động bởi alias.sh — KHÔNG source trực tiếp file này
#
# Phụ thuộc (inject từ alias.sh trước khi source):
#   _O_SCRIPT_DIR   — thư mục gốc của alias.sh
#   O_CONFIG_FILE   — đường dẫn đến .git-o-config
#   _o_resolve_auth — hàm resolve auth từ .git-o-config
#   _o_embed_token  — hàm nhúng token vào URL
#
# Flow (interactive wizard):
#   1. Đọc .git-o-config → chọn tài khoản (account / section)
#   2. Liệt kê & chọn phạm vi (Cá nhân hoặc Organization)
#   3. Gọi API lấy danh sách toàn bộ repository (hỗ trợ phân trang)
#   4. Kiểm tra repo đã tồn tại cục bộ chưa → menu chọn (Clone tất cả / theo số)
#   5. Clone có xác thực & áp dụng cấu hình tương tự oinit
#      (KHÔNG tạo .gitignore, KHÔNG tạo .opushforce.message)
# =============================================================================

[[ -n "${_O_MODULE_CLONEALL_LOADED:-}" ]] && return 0
_O_MODULE_CLONEALL_LOADED=1

# ---------------------------------------------------------------------------
# HELPER: Đọc .git-o-config → in danh sách section name
# ---------------------------------------------------------------------------
if ! declare -F _o_list_config_sections >/dev/null 2>&1; then
    function _o_list_config_sections() {
        [[ ! -f "$O_CONFIG_FILE" ]] && return 0
        grep -oP '^\[\K[^\]]+' "$O_CONFIG_FILE" | tr -d '\r'
    }
fi

# ---------------------------------------------------------------------------
# HELPER: Detect provider từ hostname
# ---------------------------------------------------------------------------
if ! declare -F _o_detect_provider >/dev/null 2>&1; then
    function _o_detect_provider() {
        local h="${1,,}"
        if   [[ "$h" == *"github.com"* ]];    then echo "github"
        elif [[ "$h" == *"dev.azure.com"* ]]; then echo "azure"
        elif [[ "$h" == *"bitbucket.org"* ]]; then echo "bitbucket"
        elif [[ "$h" == *"forgejo"* ]];       then echo "forgejo"
        elif [[ "$h" == *"gitea"* ]];         then echo "gitea"
        elif [[ "$h" == *"gitlab"* ]];        then echo "gitlab"
        else                                       echo "unknown"
        fi
    }
fi

# ---------------------------------------------------------------------------
# HELPER: Parse "host/owner[/project]" từ section name
# ---------------------------------------------------------------------------
if ! declare -F _o_parse_section >/dev/null 2>&1; then
    function _o_parse_section() {
        local section="$1"
        _O_AZURE_PROJECT_FROM_CONFIG=""
        if [[ "$section" =~ ^([^/]+)/([^/]+)/(.+)$ ]]; then
            _O_HOST="${BASH_REMATCH[1]}"
            _O_OWNER="${BASH_REMATCH[2]}"
            _O_AZURE_PROJECT_FROM_CONFIG="${BASH_REMATCH[3]}"
        elif [[ "$section" =~ ^([^/]+)/(.+)$ ]]; then
            _O_HOST="${BASH_REMATCH[1]}"
            _O_OWNER="${BASH_REMATCH[2]}"
        else
            _O_HOST="$section"
            _O_OWNER=""
        fi
    }
fi

# ---------------------------------------------------------------------------
# HELPER: Gọi GET API với auth header theo provider
# ---------------------------------------------------------------------------
function _ocla_api_get() {
    local api_url="$1"
    local provider
    provider=$(_o_detect_provider "$_O_HOST")

    local auth_header=""
    case "$O_AUTH_TYPE" in
        token)
            case "$provider" in
                github)    auth_header="Authorization: Bearer ${O_AUTH_TOKEN}" ;;
                gitlab)    auth_header="PRIVATE-TOKEN: ${O_AUTH_TOKEN}" ;;
                gitea)     auth_header="Authorization: token ${O_AUTH_TOKEN}" ;;
                forgejo)   auth_header="Authorization: token ${O_AUTH_TOKEN}" ;;
                bitbucket) auth_header="Authorization: Basic $(printf '%s' "${O_AUTH_USER}:${O_AUTH_TOKEN}" | base64 -w0)" ;;
                azure)     auth_header="Authorization: Basic $(printf '%s' ":${O_AUTH_TOKEN}" | base64 -w0)" ;;
                *)         auth_header="Authorization: Bearer ${O_AUTH_TOKEN}" ;;
            esac ;;
        header)
            auth_header="$O_AUTH_HEADER" ;;
    esac

    if [[ -n "$auth_header" ]]; then
        curl -s -H "$auth_header" \
             -H "Accept: application/json" \
             -H "User-Agent: Git-O-Alias" \
             "$api_url"
    else
        curl -s -H "Accept: application/json" \
             -H "User-Agent: Git-O-Alias" \
             "$api_url"
    fi
}

# ---------------------------------------------------------------------------
# JSON PARSERS: Parse danh sách repo (name \t clone_url)
# ---------------------------------------------------------------------------
function _ocla_parse_repos() {
    local json="$1"
    if command -v node >/dev/null 2>&1; then
        node -e '
            try {
                const fs = require("fs");
                const raw = fs.readFileSync(0, "utf8");
                const data = JSON.parse(raw);
                const items = Array.isArray(data) ? data : (data.values || data.value || []);
                items.forEach(r => {
                    const name = r.name || r.path || r.slug;
                    const url = r.clone_url || r.http_url_to_repo || r.remoteUrl ||
                                (r.links && r.links.clone && r.links.clone.find(c => c.name === "https")?.href) || "";
                    if (name && url) console.log(name + "\t" + url);
                });
            } catch(e) {}
        ' <<< "$json"
    else
        echo "$json" | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"|"(clone_url|http_url_to_repo|remoteUrl)"[[:space:]]*:[[:space:]]*"[^"]+"' | \
        awk -F'"' '
            $2 == "name" { n = $4 }
            $2 ~ /^(clone_url|http_url_to_repo|remoteUrl)$/ {
                if (n != "") { print n "\t" $4; n = "" }
            }
        '
    fi
}

# ---------------------------------------------------------------------------
# JSON PARSERS: Parse danh sách org/group
# ---------------------------------------------------------------------------
function _ocla_parse_orgs() {
    local json="$1"
    if command -v node >/dev/null 2>&1; then
        node -e '
            try {
                const fs = require("fs");
                const raw = fs.readFileSync(0, "utf8");
                const data = JSON.parse(raw);
                const items = Array.isArray(data) ? data : (data.values || []);
                items.forEach(o => {
                    const name = o.login || o.username || o.path || o.name;
                    if (name) console.log(name);
                });
            } catch(e) {}
        ' <<< "$json"
    else
        echo "$json" | grep -oE '"(login|username|path)"[[:space:]]*:[[:space:]]*"[^"]+"' | cut -d'"' -f4
    fi
}

# ---------------------------------------------------------------------------
# JSON PARSERS: Parse username cá nhân
# ---------------------------------------------------------------------------
function _ocla_parse_user() {
    local json="$1"
    if command -v node >/dev/null 2>&1; then
        node -e '
            try {
                const fs = require("fs");
                const data = JSON.parse(fs.readFileSync(0, "utf8"));
                console.log(data.login || data.username || "");
            } catch(e) {}
        ' <<< "$json"
    else
        echo "$json" | grep -oE '"(login|username)"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4
    fi
}

# ---------------------------------------------------------------------------
# HELPER: Parse chỉ số người dùng nhập (ví dụ: "1,3,5-8")
# ---------------------------------------------------------------------------
function _ocla_parse_selection() {
    local input="$1"
    local max="$2"
    local -a raw_items=()
    local -a indices=()

    IFS=', ' read -r -a raw_items <<< "$input"
    for item in "${raw_items[@]}"; do
        [[ -z "$item" ]] && continue
        if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start="${BASH_REMATCH[1]}"
            local end="${BASH_REMATCH[2]}"
            if (( start > end )); then
                local tmp=$start; start=$end; end=$tmp
            fi
            for ((k=start; k<=end; k++)); do
                if (( k >= 1 && k <= max )); then
                    indices+=("$((k - 1))")
                fi
            done
        elif [[ "$item" =~ ^[0-9]+$ ]]; then
            if (( item >= 1 && item <= max )); then
                indices+=("$((item - 1))")
            fi
        fi
    done

    # Lọc trùng
    local -a unique=()
    local -A seen=()
    for idx in "${indices[@]}"; do
        if [[ -z "${seen[$idx]:-}" ]]; then
            seen[$idx]=1
            unique+=("$idx")
        fi
    done

    printf '%s\n' "${unique[@]}"
}

# ---------------------------------------------------------------------------
# WIZARD: Bước 1 — Chọn tài khoản từ .git-o-config
# ---------------------------------------------------------------------------
function _ocla_wizard_select_account() {
    local -a sections=()
    while IFS= read -r sec; do
        [[ -n "$sec" ]] && sections+=("$sec")
    done < <(_o_list_config_sections)

    local num_sec=${#sections[@]}
    if (( num_sec == 0 )); then
        echo "  ERROR: Không có account nào trong: $O_CONFIG_FILE" >&2
        return 1
    fi

    echo "  Chọn tài khoản ($num_sec tài khoản):"
    echo ""

    local term_cols
    term_cols=$(tput cols 2>/dev/null || echo 100)
    local idx_width=${#num_sec}
    local col_width=36
    local name_width=$(( col_width - idx_width - 5 ))
    local cols=$(( term_cols / col_width ))
    (( cols < 1 )) && cols=1
    (( cols > 5 )) && cols=5
    local rows=$(( (num_sec + cols - 1) / cols ))

    local r c idx item line sec display_name
    for ((r=0; r<rows; r++)); do
        line=""
        for ((c=0; c<cols; c++)); do
            idx=$((r + c * rows))
            if (( idx < num_sec )); then
                sec="${sections[$idx]}"
                display_name="$sec"
                if (( ${#display_name} > name_width )); then
                    display_name="${display_name:0:$((name_width-3))}..."
                fi
                printf -v item "    [%-${idx_width}d] %-${name_width}s" \
                    "$((idx+1))" "$display_name"
                line+="$item"
            fi
        done
        echo "$line"
    done
    echo ""

    local choice=""
    local choice_input
    while true; do
        read -r -p "  Chọn tài khoản (số / tên / email) [1-${num_sec}]: " choice_input || return 1
        [[ -z "$choice_input" ]] && echo "  Vui lòng nhập số hoặc tên tài khoản." && continue

        # Số trực tiếp
        if [[ "$choice_input" =~ ^[0-9]+$ ]] && (( choice_input >= 1 && choice_input <= num_sec )); then
            choice=$choice_input
            break
        fi

        # Tìm kiếm theo từ khóa
        local -a matched_indices=()
        for ((i=0; i<num_sec; i++)); do
            if [[ "${sections[$i],,}" == *"${choice_input,,}"* ]]; then
                matched_indices+=($i)
            fi
        done

        if (( ${#matched_indices[@]} == 1 )); then
            choice=$((matched_indices[0] + 1))
            echo "  → Chọn: [${choice}] ${sections[$((choice-1))]}"
            break
        elif (( ${#matched_indices[@]} > 1 )); then
            echo "  Khớp ${#matched_indices[@]} kết quả:"
            for i in "${matched_indices[@]}"; do
                printf "    [%d] %s\n" "$((i+1))" "${sections[$i]}"
            done
            echo ""
            continue
        fi

        echo "  Không tìm thấy tài khoản khớp với '$choice_input'."
    done

    _OCLA_SECTION="${sections[$((choice-1))]}"
    return 0
}

# ---------------------------------------------------------------------------
# WIZARD: Bước 2 — Chọn phạm vi (Cá nhân hoặc Organization)
# ---------------------------------------------------------------------------
function _ocla_wizard_select_scope() {
    local provider
    provider=$(_o_detect_provider "$_O_HOST")

    _OCLA_SCOPE_TYPE="org"
    _OCLA_TARGET_NAME=""

    local user_name=""
    local -a orgs=()

    echo "  Đang kiểm tra danh sách Org / Cá nhân từ provider ($provider)..."

    case "$provider" in
        github)
            local user_json orgs_json
            user_json=$(_ocla_api_get "https://api.github.com/user")
            user_name=$(_ocla_parse_user "$user_json")

            orgs_json=$(_ocla_api_get "https://api.github.com/user/orgs?per_page=100")
            while IFS= read -r org; do
                [[ -n "$org" ]] && orgs+=("$org")
            done < <(_ocla_parse_orgs "$orgs_json")
            ;;
        gitea|forgejo)
            local user_json orgs_json
            user_json=$(_ocla_api_get "https://${_O_HOST}/api/v1/user")
            user_name=$(_ocla_parse_user "$user_json")

            orgs_json=$(_ocla_api_get "https://${_O_HOST}/api/v1/user/orgs?limit=100")
            while IFS= read -r org; do
                [[ -n "$org" ]] && orgs+=("$org")
            done < <(_ocla_parse_orgs "$orgs_json")
            ;;
        gitlab)
            local user_json groups_json
            user_json=$(_ocla_api_get "https://${_O_HOST}/api/v4/user")
            user_name=$(_ocla_parse_user "$user_json")

            groups_json=$(_ocla_api_get "https://${_O_HOST}/api/v4/groups?min_access_level=30&per_page=100")
            while IFS= read -r org; do
                [[ -n "$org" ]] && orgs+=("$org")
            done < <(_ocla_parse_orgs "$groups_json")
            ;;
        azure)
            # Với Azure DevOps: _O_OWNER chính là organization
            if [[ -n "$_O_OWNER" ]]; then
                echo "  Azure DevOps Organization: $_O_OWNER"
                _OCLA_SCOPE_TYPE="org"
                _OCLA_TARGET_NAME="$_O_OWNER"
                return 0
            fi
            ;;
    esac

    # Nếu section có _O_OWNER mà chưa nằm trong orgs hay user_name
    if [[ -n "$_O_OWNER" && "$_O_OWNER" != "$user_name" ]]; then
        local exists=0
        for o in "${orgs[@]}"; do
            [[ "${o,,}" == "${_O_OWNER,,}" ]] && exists=1 && break
        done
        (( exists == 0 )) && orgs=("$O_OWNER" "${orgs[@]}")
    fi

    # Hiển thị menu chọn Org / Cá nhân
    local -a scope_labels=()
    local -a scope_types=()
    local -a scope_names=()

    if [[ -n "$user_name" ]]; then
        scope_labels+=("Cá nhân: $user_name")
        scope_types+=("user")
        scope_names+=("$user_name")
    fi

    for org in "${orgs[@]}"; do
        scope_labels+=("Org: $org")
        scope_types+=("org")
        scope_names+=("$org")
    done

    local total_scopes=${#scope_labels[@]}
    echo ""
    echo "  Chọn đối tượng để clone repo:"
    for ((i=0; i<total_scopes; i++)); do
        printf "    [%d] %s\n" "$((i+1))" "${scope_labels[$i]}"
    done
    printf "    [M] Nhập tên Org hoặc Cá nhân khác thủ công\n"
    echo ""

    local sel
    while true; do
        read -r -p "  Lựa chọn [1-${total_scopes} / M]: " sel || return 1
        sel="${sel:-1}"

        if [[ "${sel,,}" == "m" ]]; then
            read -r -p "  Nhập tên Org hoặc User: " _OCLA_TARGET_NAME
            [[ -z "$_OCLA_TARGET_NAME" ]] && echo "  Tên không được để trống." && continue
            read -r -p "  Đây là [1] Org hay [2] Cá nhân? [1/2, Enter = Org]: " is_user_choice
            if [[ "$is_user_choice" == "2" ]]; then
                _OCLA_SCOPE_TYPE="user"
            else
                _OCLA_SCOPE_TYPE="org"
            fi
            return 0
        fi

        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= total_scopes )); then
            local idx=$((sel - 1))
            _OCLA_SCOPE_TYPE="${scope_types[$idx]}"
            _OCLA_TARGET_NAME="${scope_names[$idx]}"
            return 0
        fi

        echo "  Lựa chọn không hợp lệ."
    done
}

# ---------------------------------------------------------------------------
# WIZARD: Bước 3 — Gọi API lấy danh sách Repository (phân trang)
# ---------------------------------------------------------------------------
function _ocla_wizard_fetch_repos() {
    local provider
    provider=$(_o_detect_provider "$_O_HOST")

    _OCLA_REPO_NAMES=()
    _OCLA_REPO_URLS=()

    echo ""
    echo "  Đang lấy danh sách repo của $_OCLA_SCOPE_TYPE '$_OCLA_TARGET_NAME'..."

    local page=1
    local repos_raw=""

    while true; do
        local api_url=""
        case "$provider" in
            github)
                if [[ "$_OCLA_SCOPE_TYPE" == "user" ]]; then
                    api_url="https://api.github.com/users/${_OCLA_TARGET_NAME}/repos?per_page=100&type=all&page=${page}"
                else
                    api_url="https://api.github.com/orgs/${_OCLA_TARGET_NAME}/repos?per_page=100&type=all&page=${page}"
                fi
                ;;
            gitea|forgejo)
                if [[ "$_OCLA_SCOPE_TYPE" == "user" ]]; then
                    api_url="https://${_O_HOST}/api/v1/users/${_OCLA_TARGET_NAME}/repos?limit=50&page=${page}"
                else
                    api_url="https://${_O_HOST}/api/v1/orgs/${_OCLA_TARGET_NAME}/repos?limit=50&page=${page}"
                fi
                ;;
            gitlab)
                if [[ "$_OCLA_SCOPE_TYPE" == "user" ]]; then
                    api_url="https://${_O_HOST}/api/v4/users/${_OCLA_TARGET_NAME}/projects?per_page=100&page=${page}"
                else
                    api_url="https://${_O_HOST}/api/v4/groups/${_OCLA_TARGET_NAME}/projects?per_page=100&include_subgroups=true&page=${page}"
                fi
                ;;
            azure)
                api_url="https://dev.azure.com/${_OCLA_TARGET_NAME}/_apis/git/repositories?api-version=7.0"
                ;;
            *)
                echo "  Provider '$provider' chưa được hỗ trợ tự động list repo qua API." >&2
                return 1
                ;;
        esac

        local resp
        resp=$(_ocla_api_get "$api_url")
        local parsed
        parsed=$(_ocla_parse_repos "$resp")

        [[ -z "$parsed" ]] && break

        repos_raw+="$parsed"$'\n'

        # Azure chỉ trả về 1 mảng trong 1 trang
        [[ "$provider" == "azure" ]] && break

        local page_count
        page_count=$(echo "$parsed" | grep -c $'\t' || true)
        (( page_count < 50 )) && break

        (( page++ ))
        printf "  • Đã tải trang %d (%d repos)...\r" "$page" "$page_count"
    done

    while IFS=$'\t' read -r r_name r_url; do
        if [[ -n "$r_name" && -n "$r_url" ]]; then
            _OCLA_REPO_NAMES+=("$r_name")
            _OCLA_REPO_URLS+=("$r_url")
        fi
    done <<< "$repos_raw"

    local total=${#_OCLA_REPO_NAMES[@]}
    if (( total == 0 )); then
        echo "  ⚠ Không tìm thấy repository nào cho '$_OCLA_TARGET_NAME'."
        return 1
    fi

    echo "  ✓ Tìm thấy $total repository."
    return 0
}

# ---------------------------------------------------------------------------
# WIZARD: Bước 4 — Hiển thị Menu chọn repo
# ---------------------------------------------------------------------------
function _ocla_wizard_select_repos_to_clone() {
    local total=${#_OCLA_REPO_NAMES[@]}
    _OCLA_SELECTED_INDICES=()

    local -a is_exist=()
    local exist_count=0
    local missing_count=0

    for ((i=0; i<total; i++)); do
        local r_name="${_OCLA_REPO_NAMES[$i]}"
        if [[ -d "$r_name" ]]; then
            is_exist+=(1)
            (( exist_count++ ))
        else
            is_exist+=(0)
            (( missing_count++ ))
        fi
    done

    echo ""
    echo "  ┌──────────────────────────────────────────────────────────────────"
    printf "  │  Danh sách repository của %s '%s' (%d repos)\n" "$_OCLA_SCOPE_TYPE" "$_OCLA_TARGET_NAME" "$total"
    printf "  │  (Chưa có: %d | Đã có sẵn trên máy: %d)\n" "$missing_count" "$exist_count"
    echo "  ├──────────────────────────────────────────────────────────────────"

    local idx_width=${#total}
    for ((i=0; i<total; i++)); do
        local status_str="[Chưa có]"
        if (( is_exist[i] == 1 )); then
            status_str="[Đã có sẵn - Bỏ qua]"
        fi
        printf "  │  [%*d] %-38s %s\n" "$idx_width" "$((i+1))" "${_OCLA_REPO_NAMES[$i]}" "$status_str"
    done

    echo "  ├──────────────────────────────────────────────────────────────────"
    echo "  │  [A] Clone TẤT CẢ repo chưa có (Skip repo đã có)  [Mặc định]"
    echo "  │  [0] Hủy"
    echo "  └──────────────────────────────────────────────────────────────────"
    echo ""

    local choice
    read -r -p "  Lựa chọn [A / 1-${total} (vd: 1,3,5 hoặc 1-10) / 0]: " choice
    choice="${choice:-A}"

    if [[ "$choice" == "0" ]]; then
        echo "  Hủy."
        return 1
    fi

    if [[ "${choice,,}" == "a" || "${choice,,}" == "all" ]]; then
        for ((i=0; i<total; i++)); do
            if (( is_exist[i] == 0 )); then
                _OCLA_SELECTED_INDICES+=("$i")
            fi
        done
        if (( ${#_OCLA_SELECTED_INDICES[@]} == 0 )); then
            echo ""
            echo "  ✓ Tất cả các repository đều đã có sẵn trên máy cục bộ!"
            return 1
        fi
    else
        while IFS= read -r idx; do
            [[ -n "$idx" ]] && _OCLA_SELECTED_INDICES+=("$idx")
        done < <(_ocla_parse_selection "$choice" "$total")

        if (( ${#_OCLA_SELECTED_INDICES[@]} == 0 )); then
            echo "  Lựa chọn không hợp lệ."
            return 1
        fi
    fi

    return 0
}

# ---------------------------------------------------------------------------
# WIZARD: Bước 5 — Thực thi Clone & Cấu hình như oinit
# ---------------------------------------------------------------------------
function _ocla_execute_clones() {
    local total_selected=${#_OCLA_SELECTED_INDICES[@]}
    local count_cloned=0
    local count_skipped=0
    local count_failed=0

    echo ""
    echo "  Bắt đầu xử lý $total_selected repository..."
    echo "  ──────────────────────────────────────────────────────────────────"

    local template_file="${_O_SCRIPT_DIR}/git-config.template"
    local t_user_name="" t_user_email=""
    if [[ -f "$template_file" ]]; then
        t_user_name=$(git config -f "$template_file" user.name 2>/dev/null || true)
        t_user_email=$(git config -f "$template_file" user.email 2>/dev/null || true)
    fi

    local cur=0
    for idx in "${_OCLA_SELECTED_INDICES[@]}"; do
        (( cur++ ))
        local r_name="${_OCLA_REPO_NAMES[$idx]}"
        local r_url="${_OCLA_REPO_URLS[$idx]}"

        # Nếu đã có thư mục cục bộ → Bỏ qua
        if [[ -d "$r_name" ]]; then
            echo "  [$cur/$total_selected] • [skip] Thư mục đã tồn tại: $r_name"
            (( count_skipped++ ))
            continue
        fi

        echo "  [$cur/$total_selected] → Đang clone: $r_name..."

        local clone_success=0
        case "$O_AUTH_TYPE" in
            token)
                local auth_url
                auth_url=$(_o_embed_token "$r_url" "$O_AUTH_TOKEN" "$O_AUTH_USER")
                if git clone --quiet "$auth_url" "$r_name"; then
                    clone_success=1
                fi
                ;;
            header)
                if git -c "http.extraHeader=${O_AUTH_HEADER}" clone --quiet "$r_url" "$r_name"; then
                    clone_success=1
                fi
                ;;
            none|*)
                if git clone --quiet "$r_url" "$r_name"; then
                    clone_success=1
                fi
                ;;
        esac

        if (( clone_success == 1 )); then
            # Áp dụng cấu hình như oinit:
            # - Cấu hình o.url
            # - Làm sạch remote.origin.url: loại bỏ token (username:token@), chỉ lưu clean URL
            # - Cấu hình user.name, user.email từ template nếu có
            # - Cấu hình core flags
            # - KHÔNG tạo .gitignore
            # - KHÔNG tạo .opushforce.message
            (
                cd "$r_name" || exit 1
                git config o.url "$r_url"
                git config remote.origin.url "$r_url"
                [[ -n "$t_user_name" ]]  && git config user.name "$t_user_name"
                [[ -n "$t_user_email" ]] && git config user.email "$t_user_email"
                git config core.filemode false
                git config core.autocrlf false
                git config core.ignorecase true
            )
            echo "             ✓ Đã làm sạch remote.origin.url (loại bỏ token) & cấu hình o.url"
            (( count_cloned++ ))
        else
            echo "             ✗ Clone thất bại: $r_name" >&2
            (( count_failed++ ))
        fi
    done

    echo ""
    echo "  =================================================================="
    printf "  Tổng kết hoàn tất cho %s '%s':\n" "$_OCLA_SCOPE_TYPE" "$_OCLA_TARGET_NAME"
    printf "    ✓ Clone thành công : %d repo\n" "$count_cloned"
    printf "    • Bỏ qua (đã có)   : %d repo\n" "$count_skipped"
    printf "    ✗ Thất bại         : %d repo\n" "$count_failed"
    echo "  =================================================================="
    echo ""
}

# =============================================================================
# PUBLIC: ocloneall — Clone hàng loạt repo của Org hoặc Cá nhân
#
# Cú pháp:
#   git ocloneall
#   git ocla
# =============================================================================
function ocloneall() {
    echo ""
    echo "=== Git O-CloneAll — Clone hàng loạt Repository ==="
    echo ""

    # Bước 1: Chọn Account
    _ocla_wizard_select_account || return 0
    _o_parse_section "$_OCLA_SECTION"
    _o_resolve_auth "$_OCLA_SECTION"

    # Bước 2: Chọn Org hoặc Cá nhân
    _ocla_wizard_select_scope || return 0

    # Bước 3: Lấy danh sách Repo qua API
    _ocla_wizard_fetch_repos || return 0

    # Bước 4: Kiểm tra trạng thái & Menu chọn
    _ocla_wizard_select_repos_to_clone || return 0

    # Bước 5: Thực thi clone & cấu hình
    _ocla_execute_clones
}
