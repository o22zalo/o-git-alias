#!/usr/bin/env bash
# =============================================================================
# modules/oaddfile.sh — Tạo các file helper cho repo
# Được load tự động bởi alias.sh — KHÔNG source trực tiếp file này
#
# Lệnh:
#   git addfile omessage    — Tạo .opushforce.message nếu chưa có
#   git addfile ogitignore  — Tạo / append .gitignore (Node.js, .NET hoặc cả hai)
# =============================================================================

[[ -n "${_O_MODULE_ADDFILE_LOADED:-}" ]] && return 0
_O_MODULE_ADDFILE_LOADED=1

# ---------------------------------------------------------------------------
# TEMPLATE: .gitignore cho Node.js
# ---------------------------------------------------------------------------
_O_GITIGNORE_NODEJS='# ── Node.js ──────────────────────────────────────────
node_modules/
npm-debug.log*
yarn-debug.log*
yarn-error.log*
pnpm-debug.log*
.pnpm-store/
package-lock.json
yarn.lock
pnpm-lock.yaml

# Build output
dist/
build/
.next/
.nuxt/
out/
.output/
.cache/
.parcel-cache/
.turbo/

# Runtime / temp
*.log
logs/
tmp/
temp/
.tmp/

# Env & secrets
.env
.env.local
.env.*.local
.env.development
.env.production
.env.test

# Editor
.vscode/
.idea/
*.suo
*.user
*.swp
*~
.DS_Store
Thumbs.db

# Coverage
coverage/
.nyc_output/
lcov.info

# Misc
*.tgz
*.zip'

# ---------------------------------------------------------------------------
# TEMPLATE: .gitignore cho .NET / C#
# ---------------------------------------------------------------------------
_O_GITIGNORE_DOTNET='# ── .NET / C# ────────────────────────────────────────
## Build output
bin/
obj/
out/
publish/
*.user
*.suo
*.userosscache
*.sln.docstates

## NuGet
*.nupkg
*.snupkg
.nuget/
packages/
project.lock.json
project.assets.json
*.nuget.props
*.nuget.targets

## Visual Studio
.vs/
.vscode/
*.rsuser
*.vspx
*.sap
*.ncb
*.opensdf
*.sdf
*.cachefile
*.VC.db
*.VC.opendb
_ReSharper*/
*.[Rr]e[Ss]harper
*.DotSettings.user
.idea/

## Test results
TestResults/
[Tt]est[Rr]esult*/
[Bb]uild[Ll]og.*
*.log

## Publish profiles
**/Properties/PublishProfiles/*.pubxml
!**/Properties/PublishProfiles/*.pubxml.user

## Env & secrets
.env
.env.local
appsettings.Development.json
appsettings.Local.json
secrets.json

## OS
.DS_Store
Thumbs.db
*~'

# ---------------------------------------------------------------------------
# TEMPLATE: .gitignore kết hợp cả Node.js + .NET
# ---------------------------------------------------------------------------
_O_GITIGNORE_BOTH='# ── Node.js ──────────────────────────────────────────
node_modules/
npm-debug.log*
yarn-debug.log*
yarn-error.log*
pnpm-debug.log*
.pnpm-store/
package-lock.json
yarn.lock
pnpm-lock.yaml

# Build output (Node)
dist/
build/
.next/
.nuxt/
out/
.output/
.cache/
.parcel-cache/
.turbo/

# Runtime / temp
*.log
logs/
tmp/
temp/
.tmp/

# ── .NET / C# ────────────────────────────────────────
bin/
obj/
publish/
*.user
*.suo
*.userosscache
*.sln.docstates

# NuGet
*.nupkg
*.snupkg
.nuget/
packages/
project.lock.json
project.assets.json
*.nuget.props
*.nuget.targets

# Visual Studio / Rider
.vs/
_ReSharper*/
*.[Rr]e[Ss]harper
*.DotSettings.user
.idea/

# Test results
TestResults/
[Tt]est[Rr]esult*/
[Bb]uild[Ll]og.*

# Publish profiles
**/Properties/PublishProfiles/*.pubxml
!**/Properties/PublishProfiles/*.pubxml.user

# ── Shared ────────────────────────────────────────────
# Env & secrets
.env
.env.local
.env.*.local
.env.development
.env.production
.env.test
appsettings.Development.json
appsettings.Local.json
secrets.json

# Editor
.vscode/
*.swp
*~

# OS
.DS_Store
Thumbs.db
coverage/
.nyc_output/'

# ---------------------------------------------------------------------------
# TEMPLATE: Helper files của Git O-Alias
# ---------------------------------------------------------------------------
_O_GITIGNORE_O_ALIAS_HELPERS='# ── Git O-Alias helpers ───────────────────────
.git-o-config
.opushforce.message'

# ---------------------------------------------------------------------------
# HELPER: Kiểm tra một pattern đã có trong .gitignore chưa
# ---------------------------------------------------------------------------
function _oaf_already_has() {
    local file="$1" pattern="$2"
    grep -qxF "$pattern" "$file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# HELPER: Append template vào .gitignore, bỏ qua dòng đã tồn tại
# ---------------------------------------------------------------------------
function _oaf_append_gitignore() {
    local file="$1"
    local template="$2"
    local added=0 skipped=0

    # Thêm blank line ngăn cách nếu file đang có nội dung
    if [[ -s "$file" ]]; then
        local last_char
        last_char=$(tail -c1 "$file" | wc -c)
        # Đảm bảo có newline cuối + 1 dòng trống
        echo "" >> "$file"
    fi

    while IFS= read -r line; do
        # Luôn giữ comment và dòng trống nguyên vẹn (không dedup)
        if [[ -z "$line" || "$line" == \#* ]]; then
            echo "$line" >> "$file"
        else
            if _oaf_already_has "$file" "$line"; then
                (( skipped++ )) || true
            else
                echo "$line" >> "$file"
                (( added++ )) || true
            fi
        fi
    done <<< "$template"

    echo "  ✓ Đã thêm $added dòng mới, bỏ qua $skipped dòng trùng."
}

# ---------------------------------------------------------------------------
# HELPER: Đảm bảo .gitignore có ignore cho các file helper của Git O-Alias
# ---------------------------------------------------------------------------
function _oaf_ensure_o_alias_ignores() {
    local file="$1"

    [[ -f "$file" ]] || touch "$file"

    if _oaf_already_has "$file" ".git-o-config" \
       && _oaf_already_has "$file" ".opushforce.message"; then
        echo "  ✓ Git O-Alias helper ignore đã có sẵn."
        return 0
    fi

    _oaf_append_gitignore "$file" "$_O_GITIGNORE_O_ALIAS_HELPERS"
}

# ---------------------------------------------------------------------------
# HELPER: Apply template .gitignore theo profile
#   nodejs | dotnet | both
# ---------------------------------------------------------------------------
function _oaf_apply_gitignore_profile() {
    local file="$1"
    local profile="$2"
    local label=""
    local template=""

    case "$profile" in
        1|node|nodejs)
            label="Node.js"
            template="$_O_GITIGNORE_NODEJS"
            ;;
        2|dotnet|csharp|c#)
            label=".NET / C#"
            template="$_O_GITIGNORE_DOTNET"
            ;;
        3|both|fullstack)
            label="Node.js + .NET / C#"
            template="$_O_GITIGNORE_BOTH"
            ;;
        *)
            echo "[addfile ogitignore] ERROR: Profile không hợp lệ: '$profile'" >&2
            return 1
            ;;
    esac

    [[ -f "$file" ]] || touch "$file"

    echo "  Đang thêm template ${label}..."
    _oaf_append_gitignore "$file" "$template"

    echo "  Đang thêm helper ignore (.git-o-config, .opushforce.message)..."
    _oaf_ensure_o_alias_ignores "$file"
}

# ---------------------------------------------------------------------------
# HELPER: Tạo .opushforce.message nếu chưa có
# ---------------------------------------------------------------------------
function _oaf_ensure_omessage_file() {
    local target="${1:-.opushforce.message}"

    if [[ -f "$target" ]]; then
        return 1
    fi

    touch "$target"
    return 0
}

# ---------------------------------------------------------------------------
# SUB-COMMAND: omessage
# Tạo .opushforce.message trong CWD nếu chưa có
# ---------------------------------------------------------------------------
function _oaf_omessage() {
    local target=".opushforce.message"

    if ! _oaf_ensure_omessage_file "$target"; then
        echo "[addfile omessage] Đã tồn tại: $PWD/$target — bỏ qua."
        return 0
    fi

    echo "[addfile omessage] ✓ Đã tạo: $PWD/$target"
    echo "[addfile omessage]   Ghi message vào file trước khi chạy git opushforce."

    if [[ -f ".gitignore" ]]; then
        echo "[addfile omessage]   Cập nhật .gitignore để ignore file message."
        _oaf_ensure_o_alias_ignores ".gitignore"
    else
        echo "[addfile omessage]   Chưa có .gitignore — khi chạy git addfile ogitignore sẽ thêm rule ignore sẵn."
    fi
}

# ---------------------------------------------------------------------------
# SUB-COMMAND: ogitignore
# Tạo hoặc append .gitignore với template Node.js / .NET / cả hai
# ---------------------------------------------------------------------------
function _oaf_ogitignore() {
    local target=".gitignore"
    local is_new=0

    echo ""
    echo "  ┌─────────────────────────────────────────────────"
    echo "  │  git addfile ogitignore"
    if [[ -f "$target" ]]; then
        local line_count
        line_count=$(wc -l < "$target")
        echo "  │  File hiện có: $PWD/$target  ($line_count dòng)"
    else
        echo "  │  File chưa tồn tại — sẽ tạo mới: $PWD/$target"
        is_new=1
    fi
    echo "  └─────────────────────────────────────────────────"
    echo ""

    echo "  Chọn template để thêm vào .gitignore:"
    echo ""
    echo "    [1] Node.js / JavaScript / TypeScript"
    echo "        (node_modules, dist, .env, .next, yarn.lock, ...)"
    echo ""
    echo "    [2] .NET / C# (dotnet)"
    echo "        (bin, obj, .vs, packages, *.nupkg, appsettings.Local.json, ...)"
    echo ""
    echo "    [3] Cả hai  (Node.js + .NET — monorepo / fullstack)"
    echo ""
    echo "    [0] Hủy"
    echo ""

    local choice
    while true; do
        read -r -p "  Lựa chọn [0-3]: " choice
        case "$choice" in
            1|2|3|0) break ;;
            *) echo "  Nhập 0, 1, 2 hoặc 3." ;;
        esac
    done

    if [[ "$choice" == "0" ]]; then
        echo "  Hủy."
        return 0
    fi

    echo ""
    case "$choice" in
        1)
            _oaf_apply_gitignore_profile "$target" "nodejs"
            ;;
        2)
            _oaf_apply_gitignore_profile "$target" "dotnet"
            ;;
        3)
            _oaf_apply_gitignore_profile "$target" "both"
            ;;
    esac

    local total
    total=$(wc -l < "$target")
    echo "  ✓ $target hiện có $total dòng."
    echo ""

    if (( is_new )); then
        echo "  Bước tiếp: git add .gitignore && git oaddcommit"
    else
        echo "  Bước tiếp: review lại $target rồi git oaddcommit"
    fi
    echo ""
}

# =============================================================================
# PUBLIC: addfile — dispatcher
#
# Cú pháp: git addfile <sub-command>
#   omessage    — tạo .opushforce.message
#   ogitignore  — tạo / append .gitignore
# =============================================================================
function addfile() {
    local sub="${1:-}"

    case "$sub" in
        omessage)
            _oaf_omessage
            ;;
        ogitignore)
            _oaf_ogitignore
            ;;
        ""|help|--help|-h)
            echo ""
            echo "  git addfile <sub-command>"
            echo ""
            echo "  Sub-commands:"
            echo "    omessage    Tạo .opushforce.message trong CWD"
            echo "                (dùng để đặt commit message trước git opushforce)"
            echo ""
            echo "    ogitignore  Tạo / cập nhật .gitignore"
            echo "                (template Node.js, .NET/C#, hoặc cả hai)"
            echo ""
            ;;
        *)
            echo "[addfile] ERROR: Sub-command không hợp lệ: '$sub'" >&2
            echo "[addfile]   Dùng: git addfile omessage | ogitignore" >&2
            return 1
            ;;
    esac
}
