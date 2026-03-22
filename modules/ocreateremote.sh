#!/usr/bin/env bash
# =============================================================================
# modules/ocreateremote.sh — Tạo remote repo qua REST API của provider
# Được load tự động bởi alias.sh — KHÔNG source trực tiếp file này
#
# Phụ thuộc (inject từ alias.sh trước khi source file này):
#   _O_SCRIPT_DIR   — thư mục gốc của alias.sh
#   O_CONFIG_FILE   — đường dẫn đến .git-o-config
#   _o_resolve_auth — hàm resolve auth từ .git-o-config
#
# Providers hỗ trợ:
#   github.com, gitlab.com, gitlab self-hosted (hostname chứa "gitlab"),
#   dev.azure.com, gitea.*, forgejo.*, bitbucket.org
# =============================================================================

# ---------------------------------------------------------------------------
# Guard: ngăn source lại khi đã load (idempotent)
# ---------------------------------------------------------------------------
[[ -n "${_O_MODULE_CREATEREMOTE_LOADED:-}" ]] && return 0
_O_MODULE_CREATEREMOTE_LOADED=1

# ---------------------------------------------------------------------------
# HELPER: Detect provider từ hostname
# Output: "github" | "gitlab" | "azure" | "gitea" | "forgejo" | "bitbucket" | "unknown"
# ---------------------------------------------------------------------------
function _o_detect_provider() {
    local h="${1,,}"   # lowercase toàn bộ host

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
# HELPER: Parse URL → set biến _O_HOST, _O_OWNER, _O_REPO_PATH_RAW
#
# Input : https://github.com/myorg/myrepo.git
# Output: _O_HOST="github.com"  _O_OWNER="myorg"  _O_REPO_PATH_RAW="/myorg/myrepo.git"
# ---------------------------------------------------------------------------
function _o_parse_url() {
    local url="$1"
    _O_HOST=""
    _O_OWNER=""
    _O_REPO_PATH_RAW=""

    # Bỏ qua phần user:pass@ trước host nếu có (URL đã embed token)
    if [[ "$url" =~ ^https?://([^/@]+@)?([^/]+)(/.*)$ ]]; then
        _O_HOST="${BASH_REMATCH[2]}"
        _O_REPO_PATH_RAW="${BASH_REMATCH[3]}"
        if [[ "$_O_REPO_PATH_RAW" =~ ^/([^/]+)/ ]]; then
            _O_OWNER="${BASH_REMATCH[1]}"
        fi
    fi
}

# ---------------------------------------------------------------------------
# HELPER: Gọi curl API với Authorization header đúng theo provider
#
# Usage  : _o_curl_api <METHOD> <api_url> <json_body> [dry_run=0]
# Requires: O_AUTH_TYPE, O_AUTH_TOKEN, O_AUTH_USER, O_AUTH_HEADER, _O_HOST
# ---------------------------------------------------------------------------
function _o_curl_api() {
    local method="$1"
    local api_url="$2"
    local body="$3"
    local dry_run="${4:-0}"

    local provider
    provider=$(_o_detect_provider "$_O_HOST")

    # Map token → Authorization header theo từng provider
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
            esac
            ;;
        header)
            # Dùng thẳng header đã khai báo trong .git-o-config
            auth_header="$O_AUTH_HEADER"
            ;;
        none|*)
            echo "[ocreateremote] WARN: Không có auth — gọi API không xác thực" >&2
            ;;
    esac

    if [[ "$dry_run" == "1" ]]; then
        echo "[dry-run] curl -s -X $method \\"
        echo "  -H 'Content-Type: application/json' \\"
        [[ -n "$auth_header" ]] && echo "  -H '${auth_header}' \\"
        echo "  -d '${body}' \\"
        echo "  '${api_url}'"
        return 0
    fi

    if [[ -n "$auth_header" ]]; then
        curl -s -X "$method" \
            -H "Content-Type: application/json" \
            -H "$auth_header" \
            -d "$body" \
            "$api_url"
    else
        curl -s -X "$method" \
            -H "Content-Type: application/json" \
            -d "$body" \
            "$api_url"
    fi
}

# ---------------------------------------------------------------------------
# HELPER: Kiểm tra response JSON, in kết quả, offer set o.url
# ---------------------------------------------------------------------------
function _o_create_check_response() {
    local resp="$1"
    local detected_url="$2"   # URL clone lấy từ JSON response
    local fallback_url="$3"   # URL dự đoán nếu parse thất bại

    # Trích thông báo lỗi phổ biến từ JSON
    local err_msg=""
    if echo "$resp" | grep -q '"message"'; then
        err_msg=$(echo "$resp" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi
    if [[ -z "$err_msg" ]] && echo "$resp" | grep -q '"error"'; then
        err_msg=$(echo "$resp" | grep -o '"error":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi

    if [[ -n "$detected_url" ]]; then
        echo ""
        echo "[ocreateremote] ✓ Repo đã tạo thành công!"
        echo "[ocreateremote]   Clone URL: $detected_url"
        echo ""
        # Offer set o.url nếu đang trong git repo
        if git rev-parse --git-dir &>/dev/null 2>&1; then
            read -r -p "[ocreateremote] Set o.url = $detected_url cho repo này? [Y/n] " yn
            yn="${yn:-Y}"
            if [[ "${yn,,}" == "y" ]]; then
                git config o.url "$detected_url"
                echo "[ocreateremote] ✓ o.url đã được set. Chạy ngay: git opush"
            fi
        fi
    else
        echo "" >&2
        echo "[ocreateremote] ✗ Tạo repo thất bại." >&2
        [[ -n "$err_msg" ]] && echo "[ocreateremote]   Lỗi API: $err_msg" >&2
        echo "" >&2
        echo "[ocreateremote]   Raw response:" >&2
        echo "$resp" >&2
        echo "" >&2
        echo "[ocreateremote]   Fallback URL (chưa verify): $fallback_url" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# PROVIDER: GitHub
# POST /orgs/{org}/repos  →  fallback POST /user/repos
# Docs: https://docs.github.com/en/rest/repos/repos#create-an-organization-repository
# ---------------------------------------------------------------------------
function _o_create_github() {
    local host="$1" owner="$2" repo_name="$3" desc="$4" is_private="$5" dry_run="$6"

    local body
    body=$(printf '{"name":"%s","description":"%s","private":%s,"auto_init":false}' \
        "$repo_name" "$desc" "$is_private")

    echo "[ocreateremote] GitHub | Owner: $owner | Repo: $repo_name" >&2

    local resp
    resp=$(_o_curl_api POST "https://api.github.com/orgs/${owner}/repos" "$body" "$dry_run")
    [[ "$dry_run" == "1" ]] && return 0

    local html_url
    html_url=$(echo "$resp" | grep -o '"html_url":"[^"]*"' | head -1 | cut -d'"' -f4)

    # Fallback: tạo trong user account nếu owner không phải org
    if [[ -z "$html_url" ]]; then
        echo "[ocreateremote] Thử /user/repos (personal account)..." >&2
        resp=$(_o_curl_api POST "https://api.github.com/user/repos" "$body" "$dry_run")
        html_url=$(echo "$resp" | grep -o '"html_url":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi

    local clone_url=""
    [[ -n "$html_url" ]] && clone_url="${html_url}.git"

    _o_create_check_response "$resp" "$clone_url" \
        "https://github.com/${owner}/${repo_name}.git"
}

# ---------------------------------------------------------------------------
# PROVIDER: GitLab (cloud + self-hosted)
# POST /api/v4/projects
# Docs: https://docs.gitlab.com/ee/api/projects.html#create-project
# ---------------------------------------------------------------------------
function _o_create_gitlab() {
    local host="$1" owner="$2" repo_name="$3" desc="$4" is_private="$5" dry_run="$6"

    local visibility
    [[ "$is_private" == "true" ]] && visibility="private" || visibility="public"

    local body
    body=$(printf '{"name":"%s","description":"%s","visibility":"%s","namespace_path":"%s","initialize_with_readme":false}' \
        "$repo_name" "$desc" "$visibility" "$owner")

    echo "[ocreateremote] GitLab ($host) | Namespace: $owner | Repo: $repo_name" >&2

    local resp
    resp=$(_o_curl_api POST "https://${host}/api/v4/projects" "$body" "$dry_run")
    [[ "$dry_run" == "1" ]] && return 0

    local clone_url
    clone_url=$(echo "$resp" | grep -o '"http_url_to_repo":"[^"]*"' | head -1 | cut -d'"' -f4)

    _o_create_check_response "$resp" "$clone_url" \
        "https://${host}/${owner}/${repo_name}.git"
}

# ---------------------------------------------------------------------------
# PROVIDER: Gitea + Forgejo (API tương thích nhau)
# POST /api/v1/orgs/{org}/repos  →  fallback POST /api/v1/user/repos
# Docs: https://gitea.com/api/swagger
# ---------------------------------------------------------------------------
function _o_create_gitea() {
    local host="$1" owner="$2" repo_name="$3" desc="$4" is_private="$5" dry_run="$6"
    local provider_label="${7:-Gitea}"

    local body
    body=$(printf '{"name":"%s","description":"%s","private":%s,"auto_init":false}' \
        "$repo_name" "$desc" "$is_private")

    echo "[ocreateremote] $provider_label ($host) | Owner: $owner | Repo: $repo_name" >&2

    local resp
    resp=$(_o_curl_api POST "https://${host}/api/v1/orgs/${owner}/repos" "$body" "$dry_run")
    [[ "$dry_run" == "1" ]] && return 0

    local clone_url
    clone_url=$(echo "$resp" | grep -o '"clone_url":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [[ -z "$clone_url" ]]; then
        echo "[ocreateremote] Thử /api/v1/user/repos (personal account)..." >&2
        resp=$(_o_curl_api POST "https://${host}/api/v1/user/repos" "$body" "$dry_run")
        clone_url=$(echo "$resp" | grep -o '"clone_url":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi

    _o_create_check_response "$resp" "$clone_url" \
        "https://${host}/${owner}/${repo_name}.git"
}

# ---------------------------------------------------------------------------
# PROVIDER: Bitbucket Cloud
# POST /2.0/repositories/{workspace}/{repo_slug}
# Docs: https://developer.atlassian.com/cloud/bitbucket/rest/api-group-repositories
# ---------------------------------------------------------------------------
function _o_create_bitbucket() {
    local host="$1" owner="$2" repo_name="$3" desc="$4" is_private="$5" dry_run="$6"

    # Bitbucket slug: lowercase
    local slug="${repo_name,,}"

    local body
    body=$(printf '{"scm":"git","name":"%s","description":"%s","is_private":%s}' \
        "$repo_name" "$desc" "$is_private")

    echo "[ocreateremote] Bitbucket | Workspace: $owner | Repo: $slug" >&2

    local resp
    resp=$(_o_curl_api POST "https://api.bitbucket.org/2.0/repositories/${owner}/${slug}" "$body" "$dry_run")
    [[ "$dry_run" == "1" ]] && return 0

    # Response trả về links.clone array — lấy href có scheme https
    local clone_url
    clone_url=$(echo "$resp" | grep -o '"href":"https://[^"]*\.git"' | head -1 | cut -d'"' -f4)

    _o_create_check_response "$resp" "$clone_url" \
        "https://bitbucket.org/${owner}/${slug}.git"
}

# ---------------------------------------------------------------------------
# PROVIDER: Azure DevOps
# POST /{org}/{project}/_apis/git/repositories?api-version=7.1
# Docs: https://learn.microsoft.com/en-us/rest/api/azure/devops/git/repositories/create
# Lưu ý: Azure không quản lý public/private ở cấp repo (quản lý qua Project)
# ---------------------------------------------------------------------------
function _o_create_azure() {
    local host="$1" owner="$2" repo_name="$3" desc="$4" is_private="$5" dry_run="$6"

    # Trích org và project từ _O_REPO_PATH_RAW
    # Format: /{org}/{project}/_git/{repo}
    local org="$owner"
    local project=""
    if [[ "$_O_REPO_PATH_RAW" =~ ^/([^/]+)/([^/]+)/_git ]]; then
        org="${BASH_REMATCH[1]}"
        project="${BASH_REMATCH[2]}"
    fi

    if [[ -z "$project" ]]; then
        echo "[ocreateremote] ERROR: Azure DevOps cần project name." >&2
        echo "[ocreateremote]   Thêm --project <tên> khi gọi lệnh, hoặc đảm bảo o.url có dạng:" >&2
        echo "[ocreateremote]   https://dev.azure.com/{org}/{project}/_git/{repo}" >&2
        return 1
    fi

    if [[ "$is_private" == "false" ]]; then
        echo "[ocreateremote] INFO: Azure DevOps không hỗ trợ public repo qua API." >&2
        echo "[ocreateremote]   Visibility được quản lý ở cấp Project trên portal." >&2
    fi

    local body
    body=$(printf '{"name":"%s"}' "$repo_name")

    echo "[ocreateremote] Azure DevOps | Org: $org | Project: $project | Repo: $repo_name" >&2

    local resp
    resp=$(_o_curl_api POST \
        "https://dev.azure.com/${org}/${project}/_apis/git/repositories?api-version=7.1" \
        "$body" "$dry_run")
    [[ "$dry_run" == "1" ]] && return 0

    local remote_url
    remote_url=$(echo "$resp" | grep -o '"remoteUrl":"[^"]*"' | head -1 | cut -d'"' -f4)

    _o_create_check_response "$resp" "$remote_url" \
        "https://dev.azure.com/${org}/${project}/_git/${repo_name}"
}

# ---------------------------------------------------------------------------
# PUBLIC: ocreateremote — Entry point chính
#
# Cú pháp: git ocreateremote [OPTIONS]
#
# OPTIONS:
#   --public              Tạo repo public (mặc định: private)
#   --private             Tạo repo private (mặc định, có thể bỏ qua)
#   --name  <tên>         Tên repo (mặc định: lấy từ o.url, fallback: tên CWD)
#   --desc  <text>        Mô tả repo
#   --url   <url>         Override o.url để chỉ định provider/owner
#   --project <tên>       Tên project — chỉ dùng cho Azure DevOps
#   --dry-run             In lệnh curl, không gọi API thật
#   -h, --help            Hiện help
# ---------------------------------------------------------------------------
function ocreateremote() {
    # ── Parse arguments ──────────────────────────────────────────────────────
    local is_private="true"
    local repo_name=""
    local description=""
    local override_url=""
    local dry_run="0"
    local azure_project=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --public)             is_private="false"; shift ;;
            --private)            is_private="true";  shift ;;
            --name)               repo_name="$2";     shift 2 ;;
            --desc|--description) description="$2";   shift 2 ;;
            --url)                override_url="$2";  shift 2 ;;
            --project)            azure_project="$2"; shift 2 ;;
            --dry-run)            dry_run="1";        shift ;;
            -h|--help)
                echo ""
                echo "Cú pháp: git ocreateremote [OPTIONS]"
                echo ""
                echo "OPTIONS:"
                echo "  --public              Tạo repo public (mặc định: private)"
                echo "  --private             Tạo repo private (có thể bỏ qua)"
                echo "  --name  <tên>         Tên repo (mặc định: lấy từ o.url hoặc tên CWD)"
                echo "  --desc  <text>        Mô tả repo"
                echo "  --url   <url>         Override o.url để chỉ định provider/owner"
                echo "  --project <tên>       Project name (chỉ Azure DevOps)"
                echo "  --dry-run             In curl command, không gọi API thật"
                echo ""
                echo "Providers: github.com, gitlab.com, gitlab self-hosted,"
                echo "           dev.azure.com, gitea.*, forgejo.*, bitbucket.org"
                echo ""
                echo "Ví dụ:"
                echo "  git ocreateremote"
                echo "  git ocreateremote --public"
                echo "  git ocreateremote --name my-lib --desc 'Thư viện dùng chung'"
                echo "  git ocreateremote --url https://github.com/myorg/newrepo.git --public"
                echo "  git ocreateremote --dry-run"
                echo ""
                return 0
                ;;
            *)
                echo "[ocreateremote] WARN: Option không nhận ra: '$1' (bỏ qua)" >&2
                shift
                ;;
        esac
    done

    # ── Xác định target URL ──────────────────────────────────────────────────
    local target_url
    if [[ -n "$override_url" ]]; then
        target_url="$override_url"
    else
        target_url=$(git config --get o.url 2>/dev/null || true)
        if [[ -z "$target_url" ]]; then
            echo "[ocreateremote] ERROR: Chưa set o.url và không có --url." >&2
            echo "[ocreateremote]   Gợi ý:" >&2
            echo "[ocreateremote]     git config o.url https://github.com/myorg/newrepo.git" >&2
            echo "[ocreateremote]     git ocreateremote --url https://github.com/myorg/newrepo.git" >&2
            return 1
        fi
    fi

    # ── Parse URL → _O_HOST, _O_OWNER, _O_REPO_PATH_RAW ─────────────────────
    _o_parse_url "$target_url"

    if [[ -z "$_O_HOST" ]]; then
        echo "[ocreateremote] ERROR: Không parse được host từ URL: $target_url" >&2
        return 1
    fi

    # ── Inject azure_project nếu user truyền --project ───────────────────────
    if [[ -n "$azure_project" ]]; then
        _O_REPO_PATH_RAW="/${_O_OWNER}/${azure_project}/_git/__placeholder__"
    fi

    # ── Xác định tên repo ─────────────────────────────────────────────────────
    if [[ -z "$repo_name" ]]; then
        local url_repo_name
        url_repo_name=$(basename "$target_url" .git)
        local cwd_name
        cwd_name=$(basename "$PWD")

        # Fallback sang tên CWD nếu URL còn là placeholder
        local invalid_names=("oremoteUrl" "__placeholder__" "" "$_O_HOST")
        local use_cwd=0
        for inv in "${invalid_names[@]}"; do
            [[ "$url_repo_name" == "$inv" ]] && use_cwd=1 && break
        done

        repo_name=$( [[ "$use_cwd" == "1" ]] && echo "$cwd_name" || echo "$url_repo_name" )
    fi

    # Sanitize: lowercase, space → gạch ngang
    repo_name="${repo_name,,}"
    repo_name="${repo_name// /-}"

    # ── Resolve auth (dùng hàm từ alias.sh) ──────────────────────────────────
    _o_resolve_auth "$target_url"

    if [[ "$O_AUTH_TYPE" == "none" ]]; then
        echo "[ocreateremote] WARN: Không tìm thấy auth trong: $O_CONFIG_FILE" >&2
    fi

    # ── Detect provider ───────────────────────────────────────────────────────
    local provider
    provider=$(_o_detect_provider "$_O_HOST")

    # Heuristic bổ sung cho self-hosted không rõ tên từ hostname
    if [[ "$provider" == "unknown" && "$O_AUTH_TYPE" == "header" ]]; then
        if [[ "$O_AUTH_HEADER" == *"glpat"* || "$O_AUTH_HEADER" == *"PRIVATE-TOKEN"* ]]; then
            provider="gitlab"
        elif [[ "$O_AUTH_HEADER" == "Authorization: token "* ]]; then
            provider="gitea"
        fi
    fi

    # ── Print summary ─────────────────────────────────────────────────────────
    local vis_label
    [[ "$is_private" == "true" ]] && vis_label="private 🔒" || vis_label="public 🌐"

    echo ""
    echo "┌──────────────────────────────────────────────"
    echo "│  git ocreateremote"
    echo "├──────────────────────────────────────────────"
    printf "│  Provider   : %s\n"   "$provider"
    printf "│  Host       : %s\n"   "$_O_HOST"
    printf "│  Owner/Org  : %s\n"   "$_O_OWNER"
    printf "│  Repo name  : %s\n"   "$repo_name"
    printf "│  Visibility : %s\n"   "$vis_label"
    [[ -n "$description" ]] && printf "│  Desc       : %s\n" "$description"
    printf "│  Auth       : %s @ [%s]\n" "$O_AUTH_TYPE" "$O_AUTH_MATCH"
    [[ "$dry_run" == "1" ]] && printf "│  Mode       : DRY RUN\n"
    echo "└──────────────────────────────────────────────"
    echo ""

    if [[ "$dry_run" != "1" ]]; then
        read -r -p "[ocreateremote] Xác nhận tạo repo? [Y/n] " confirm
        confirm="${confirm:-Y}"
        if [[ "${confirm,,}" != "y" ]]; then
            echo "[ocreateremote] Hủy."
            return 0
        fi
    fi

    # ── Dispatch sang provider handler ───────────────────────────────────────
    case "$provider" in
        github)
            _o_create_github    "$_O_HOST" "$_O_OWNER" "$repo_name" "$description" "$is_private" "$dry_run"
            ;;
        gitlab)
            _o_create_gitlab    "$_O_HOST" "$_O_OWNER" "$repo_name" "$description" "$is_private" "$dry_run"
            ;;
        gitea)
            _o_create_gitea     "$_O_HOST" "$_O_OWNER" "$repo_name" "$description" "$is_private" "$dry_run" "Gitea"
            ;;
        forgejo)
            _o_create_gitea     "$_O_HOST" "$_O_OWNER" "$repo_name" "$description" "$is_private" "$dry_run" "Forgejo"
            ;;
        bitbucket)
            _o_create_bitbucket "$_O_HOST" "$_O_OWNER" "$repo_name" "$description" "$is_private" "$dry_run"
            ;;
        azure)
            _o_create_azure     "$_O_HOST" "$_O_OWNER" "$repo_name" "$description" "$is_private" "$dry_run"
            ;;
        unknown)
            echo "[ocreateremote] ERROR: Không nhận ra provider từ host '$_O_HOST'." >&2
            echo "[ocreateremote]   Providers hỗ trợ: github.com, gitlab.com (và self-hosted chứa 'gitlab' trong hostname)," >&2
            echo "[ocreateremote]   dev.azure.com, gitea.*, forgejo.*, bitbucket.org" >&2
            echo "[ocreateremote]   Nếu là GitLab self-hosted với domain riêng, đảm bảo hostname chứa 'gitlab'." >&2
            return 1
            ;;
    esac
}