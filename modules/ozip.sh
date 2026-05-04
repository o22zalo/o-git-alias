#!/usr/bin/env bash
# =============================================================================
# modules/ozip.sh — Download source code ZIP từ remote repo
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
#   2. Hiển thị menu chọn URL (Enter = dùng o.url mặc định)
#   3. Parse URL → host / owner / repo
#   4. Lấy danh sách branch từ remote với auth (ls-remote)
#   5. Hiển thị menu chọn branch (Enter = main)
#   6. Build URL tải ZIP theo từng provider
#   7. Download bằng curl → lưu vào thư mục Downloads của Windows
# =============================================================================

[[ -n "${_O_MODULE_OZIP_LOADED:-}" ]] && return 0
_O_MODULE_OZIP_LOADED=1

# ---------------------------------------------------------------------------
# HELPER: Detect provider từ hostname (tự chứa, không phụ thuộc ocreateremote)
# ---------------------------------------------------------------------------
function _ozip_detect_provider() {
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

# ---------------------------------------------------------------------------
# HELPER: Parse URL → set _OZIP_HOST, _OZIP_OWNER, _OZIP_REPO, _OZIP_AZURE_PROJECT
# ---------------------------------------------------------------------------
function _ozip_parse_url() {
    local url="$1"
    _OZIP_HOST="" _OZIP_OWNER="" _OZIP_REPO="" _OZIP_AZURE_PROJECT=""

    # Bỏ auth prefix (user:token@host)
    local clean_url="$url"
    if [[ "$clean_url" =~ ^(https://)([^@]+@)(.+)$ ]]; then
        clean_url="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
    fi

    # Azure DevOps: https://dev.azure.com/{org}/{project}/_git/{repo}[.git]
    if [[ "$clean_url" =~ ^https://dev\.azure\.com/([^/]+)/([^/]+)/_git/([^/.]+)(\.git)?/?$ ]]; then
        _OZIP_HOST="dev.azure.com"
        _OZIP_OWNER="${BASH_REMATCH[1]}"
        _OZIP_AZURE_PROJECT="${BASH_REMATCH[2]}"
        _OZIP_REPO="${BASH_REMATCH[3]}"
        return 0
    fi

    # Standard HTTPS: https://host/owner/repo[.git]
    if [[ "$clean_url" =~ ^https://([^/]+)/([^/]+)/([^/.]+)(\.git)?/?$ ]]; then
        _OZIP_HOST="${BASH_REMATCH[1]}"
        _OZIP_OWNER="${BASH_REMATCH[2]}"
        _OZIP_REPO="${BASH_REMATCH[3]}"
        return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# HELPER: Build URL tải ZIP theo provider
#   $1=host  $2=owner  $3=repo  $4=branch  $5=azure_project (optional)
# ---------------------------------------------------------------------------
function _ozip_build_zip_url() {
    local host="$1" owner="$2" repo="$3" branch="$4" azure_project="${5:-}"

    case "$(_ozip_detect_provider "$host")" in
        github)
            echo "https://github.com/${owner}/${repo}/archive/refs/heads/${branch}.zip"
            ;;
        gitlab)
            echo "https://${host}/${owner}/${repo}/-/archive/${branch}/${repo}-${branch}.zip"
            ;;
        gitea|forgejo)
            echo "https://${host}/${owner}/${repo}/archive/${branch}.zip"
            ;;
        bitbucket)
            echo "https://bitbucket.org/${owner}/${repo}/get/${branch}.zip"
            ;;
        azure)
            # Azure DevOps Items API — trả ZIP toàn bộ repo tại branch chỉ định
            local encoded_branch="${branch//\//%2F}"
            echo "https://dev.azure.com/${owner}/${azure_project}/_apis/git/repositories/${repo}/items?path=%2F&versionDescriptor%5BversionType%5D=branch&versionDescriptor%5Bversion%5D=${encoded_branch}&resolveLfs=true&%24format=zip&api-version=7.1&download=true"
            ;;
        *)
            # Self-hosted không xác định → thử Gitea-style (phổ biến nhất)
            echo "https://${host}/${owner}/${repo}/archive/${branch}.zip"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# HELPER: Lấy danh sách branch từ remote (ls-remote với auth)
# Output: mỗi dòng 1 branch name, đã sort. "" nếu thất bại.
# ---------------------------------------------------------------------------
function _ozip_list_remote_branches() {
    local url="$1"
    _o_resolve_auth "$url"

    case "$O_AUTH_TYPE" in
        token)
            local auth_url
            auth_url=$(_o_embed_token "$url" "$O_AUTH_TOKEN" "$O_AUTH_USER")
            git ls-remote --heads "$auth_url" 2>/dev/null \
                | awk '{sub(/.*refs\/heads\//, ""); print}' \
                | sort
            ;;
        header)
            git -c "http.extraHeader=${O_AUTH_HEADER}" ls-remote --heads "$url" 2>/dev/null \
                | awk '{sub(/.*refs\/heads\//, ""); print}' \
                | sort
            ;;
        none|*)
            git ls-remote --heads "$url" 2>/dev/null \
                | awk '{sub(/.*refs\/heads\//, ""); print}' \
                | sort
            ;;
    esac
}

# ---------------------------------------------------------------------------
# HELPER: In curl auth args — mỗi flag/value 1 dòng riêng
#         Caller đọc vào mảng: while read; do auth_args+=("$line"); done
# ---------------------------------------------------------------------------
function _ozip_get_curl_auth_args() {
    local host="$1"

    case "$O_AUTH_TYPE" in
        token)
            case "$(_ozip_detect_provider "$host")" in
                github)
                    printf '%s\n' "-H" "Authorization: token ${O_AUTH_TOKEN}"
                    ;;
                gitlab)
                    printf '%s\n' "-H" "PRIVATE-TOKEN: ${O_AUTH_TOKEN}"
                    ;;
                gitea|forgejo)
                    printf '%s\n' "-H" "Authorization: token ${O_AUTH_TOKEN}"
                    ;;
                bitbucket)
                    # Bitbucket dùng App Password → user:password
                    printf '%s\n' "-u" "${O_AUTH_USER}:${O_AUTH_TOKEN}"
                    ;;
                azure)
                    local b64
                    b64=$(printf '%s' ":${O_AUTH_TOKEN}" | base64 -w0 2>/dev/null \
                          || printf '%s' ":${O_AUTH_TOKEN}" | base64)
                    printf '%s\n' "-H" "Authorization: Basic ${b64}"
                    ;;
                *)
                    printf '%s\n' "-H" "Authorization: Bearer ${O_AUTH_TOKEN}"
                    ;;
            esac
            ;;
        header)
            printf '%s\n' "-H" "$O_AUTH_HEADER"
            ;;
        none|*)
            # Không có auth — không in gì
            ;;
    esac
}

# ---------------------------------------------------------------------------
# HELPER: Lấy đường dẫn thư mục Downloads của Windows trong Git Bash
# ---------------------------------------------------------------------------
function _ozip_get_downloads_dir() {
    local dir=""

    if [[ -n "${USERPROFILE:-}" ]]; then
        if command -v cygpath &>/dev/null; then
            dir="$(cygpath -u "$USERPROFILE")/Downloads"
        else
            # Chuyển thủ công Windows path → Unix path
            dir="${USERPROFILE//\\//}/Downloads"
        fi
    fi

    # Fallback: thư mục home
    if [[ -z "$dir" ]]; then
        dir="${HOME}/Downloads"
    fi

    mkdir -p "$dir" 2>/dev/null || true
    echo "$dir"
}

# =============================================================================
# PUBLIC: ozip — Download source ZIP từ remote repo
#
# Cú pháp: git ozip
#          git oz
# =============================================================================
function ozip() {

    # ── Kiểm tra môi trường ───────────────────────────────────────────────────
    if ! git rev-parse --git-dir &>/dev/null 2>&1; then
        echo "[ozip] ERROR: Không phải git repo." >&2
        return 1
    fi

    if ! command -v curl &>/dev/null; then
        echo "[ozip] ERROR: Cần cài 'curl' để tải file." >&2
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
        echo "[ozip] ERROR: Không tìm thấy o.url nào trong .git/config." >&2
        echo "[ozip]   Thiết lập: git config o.url https://github.com/org/repo.git" >&2
        return 1
    fi

    # ── Header ───────────────────────────────────────────────────────────────
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────"
    echo "  │  git ozip — Download source ZIP"
    echo "  └─────────────────────────────────────────────────────────────"
    echo ""

    # ── Chọn remote URL ───────────────────────────────────────────────────────
    local selected_url selected_key

    if [[ ${#url_vals[@]} -eq 1 ]]; then
        # Chỉ có 1 URL → dùng luôn, không hỏi
        selected_key="${url_keys[0]}"
        selected_url="${url_vals[0]}"
        echo "  Remote : $selected_key  →  $selected_url"
    else
        echo "  Chọn remote URL (Enter = o.url mặc định):"
        echo ""

        local j
        for j in "${!url_vals[@]}"; do
            printf "    [%d] %-12s  %s\n" "$((j+1))" "${url_keys[$j]}" "${url_vals[$j]}"
        done
        echo ""

        local choice_url
        read -r -p "  Số thứ tự [1-${#url_vals[@]}, Enter = 1]: " choice_url
        choice_url="${choice_url:-1}"

        if ! [[ "$choice_url" =~ ^[0-9]+$ ]] \
           || (( choice_url < 1 || choice_url > ${#url_vals[@]} )); then
            choice_url=1
        fi

        selected_key="${url_keys[$((choice_url-1))]}"
        selected_url="${url_vals[$((choice_url-1))]}"
        echo "  → Remote : $selected_key  →  $selected_url"
    fi

    # ── Parse URL → host / owner / repo ──────────────────────────────────────
    if ! _ozip_parse_url "$selected_url"; then
        echo "[ozip] ERROR: Không parse được URL: $selected_url" >&2
        return 1
    fi

    if [[ -z "$_OZIP_HOST" || -z "$_OZIP_OWNER" || -z "$_OZIP_REPO" ]]; then
        echo "[ozip] ERROR: Không lấy được host/owner/repo từ URL." >&2
        return 1
    fi

    echo ""
    printf "  Host  : %s\n" "$_OZIP_HOST"
    printf "  Owner : %s\n" "$_OZIP_OWNER"
    printf "  Repo  : %s\n" "$_OZIP_REPO"
    [[ -n "$_OZIP_AZURE_PROJECT" ]] && printf "  Project: %s\n" "$_OZIP_AZURE_PROJECT"

    # ── Resolve auth ──────────────────────────────────────────────────────────
    _o_resolve_auth "$selected_url"

    # ── Lấy danh sách branch ──────────────────────────────────────────────────
    echo ""
    printf "  Đang lấy danh sách branch từ %s ...\n" "$_OZIP_HOST"

    local -a branches=()
    local bline
    while IFS= read -r bline; do
        [[ -n "$bline" ]] && branches+=("$bline")
    done < <(_ozip_list_remote_branches "$selected_url")

    local selected_branch

    if [[ ${#branches[@]} -eq 0 ]]; then
        echo "  ⚠ Không lấy được danh sách branch (auth lỗi hoặc repo trống)."
        read -r -p "  Nhập tên branch [main]: " selected_branch
        selected_branch="${selected_branch:-main}"
    else
        echo ""
        echo "  Chọn branch (Enter = main):"
        echo ""

        local k
        for k in "${!branches[@]}"; do
            local marker=""
            [[ "${branches[$k]}" == "main" ]] && marker="  ← mặc định"
            printf "    [%d] %s%s\n" "$((k+1))" "${branches[$k]}" "$marker"
        done
        echo ""

        local choice_branch
        read -r -p "  Số thứ tự [1-${#branches[@]}, Enter = main]: " choice_branch

        if [[ -z "$choice_branch" ]]; then
            # Enter → ưu tiên "main", nếu không có thì lấy branch đầu tiên
            selected_branch="main"
            local found_main=0
            for bname in "${branches[@]}"; do
                [[ "$bname" == "main" ]] && found_main=1 && break
            done
            if (( ! found_main )) && [[ ${#branches[@]} -gt 0 ]]; then
                selected_branch="${branches[0]}"
            fi
        elif [[ "$choice_branch" =~ ^[0-9]+$ ]] \
             && (( choice_branch >= 1 && choice_branch <= ${#branches[@]} )); then
            selected_branch="${branches[$((choice_branch-1))]}"
        else
            # Input không hợp lệ → cho nhập tay
            read -r -p "  Nhập tên branch [main]: " selected_branch
            selected_branch="${selected_branch:-main}"
        fi
    fi

    echo "  → Branch : $selected_branch"

    # ── Build ZIP URL theo provider ───────────────────────────────────────────
    local zip_url
    zip_url=$(_ozip_build_zip_url \
        "$_OZIP_HOST" "$_OZIP_OWNER" "$_OZIP_REPO" \
        "$selected_branch" "$_OZIP_AZURE_PROJECT")

    echo ""
    echo "  ZIP URL : $zip_url"

    # ── Xác định đường dẫn lưu ───────────────────────────────────────────────
    local downloads_dir
    downloads_dir=$(_ozip_get_downloads_dir)

    # Thay / thành - trong tên branch (vd: feature/auth → feature-auth)
    local safe_branch="${selected_branch//\//-}"
    local out_filename="${_OZIP_REPO}-${safe_branch}.zip"
    local out_path="${downloads_dir}/${out_filename}"

    echo "  Lưu vào : $out_path"
    echo ""

    # ── Build mảng lệnh curl ─────────────────────────────────────────────────
    local -a curl_cmd=()
    curl_cmd+=("curl")
    curl_cmd+=("-L")              # follow redirects (GitHub, GitLab đều redirect)
    curl_cmd+=("-f")              # fail ngay khi HTTP error (tránh lưu trang lỗi HTML)
    curl_cmd+=("--progress-bar") # thanh tiến trình đơn giản
    curl_cmd+=("-o" "$out_path")

    # Auth args (đọc từng dòng vào mảng)
    local -a auth_args=()
    while IFS= read -r aline; do
        [[ -n "$aline" ]] && auth_args+=("$aline")
    done < <(_ozip_get_curl_auth_args "$_OZIP_HOST")

    curl_cmd+=("${auth_args[@]}")
    curl_cmd+=("$zip_url")

    # ── Download ──────────────────────────────────────────────────────────────
    echo "  [ozip] Đang tải..."
    echo ""

    local curl_exit=0
    "${curl_cmd[@]}" || curl_exit=$?

    echo ""

    if (( curl_exit == 0 )) && [[ -f "$out_path" && -s "$out_path" ]]; then
        local file_size=""
        command -v du &>/dev/null \
            && file_size=$(du -sh "$out_path" 2>/dev/null | cut -f1)

        echo "  ✓ Download thành công!"
        echo "  ✓ File : $out_path"
        [[ -n "$file_size" ]] && echo "  ✓ Size : $file_size"
        echo ""

        # Hỏi có muốn copy đường dẫn file ZIP vào clipboard không
        local confirm_copy_path
        read -r -p "  Copy đường dẫn file ZIP vào clipboard? [Y/n]: " confirm_copy_path
        confirm_copy_path="${confirm_copy_path:-Y}"

        if [[ "${confirm_copy_path,,}" == "y" ]]; then
            local clip_path="$out_path"

            # Trên Windows Git Bash, ưu tiên copy đường dẫn dạng Windows cho tiện dán vào Explorer/ứng dụng Windows
            if command -v cygpath &>/dev/null; then
                clip_path=$(cygpath -w "$out_path" 2>/dev/null || echo "$out_path")
            fi

            if command -v clip.exe &>/dev/null; then
                printf '%s' "$clip_path" | clip.exe
                echo "  ✓ Đã copy đường dẫn vào clipboard: $clip_path"
            elif command -v powershell.exe &>/dev/null; then
                printf '%s' "$clip_path" | powershell.exe -NoProfile -Command "Set-Clipboard -Value ([Console]::In.ReadToEnd())" >/dev/null 2>&1
                echo "  ✓ Đã copy đường dẫn vào clipboard: $clip_path"
            elif command -v pbcopy &>/dev/null; then
                printf '%s' "$clip_path" | pbcopy
                echo "  ✓ Đã copy đường dẫn vào clipboard: $clip_path"
            elif command -v xclip &>/dev/null; then
                printf '%s' "$clip_path" | xclip -selection clipboard
                echo "  ✓ Đã copy đường dẫn vào clipboard: $clip_path"
            elif command -v xsel &>/dev/null; then
                printf '%s' "$clip_path" | xsel --clipboard --input
                echo "  ✓ Đã copy đường dẫn vào clipboard: $clip_path"
            else
                echo "  ⚠ Không tìm thấy công cụ clipboard phù hợp. Hãy copy thủ công đường dẫn sau:"
                echo "    $clip_path"
            fi
        fi
    else
        echo "  ✗ Download thất bại (curl exit: $curl_exit)." >&2
        echo "  ✗ Kiểm tra lại URL, auth token và kết nối mạng." >&2
        echo "  ✗ ZIP URL : $zip_url" >&2
        [[ -f "$out_path" ]] && rm -f "$out_path"
        return 1
    fi

    echo ""
}
