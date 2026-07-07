#!/usr/bin/env bash
# =============================================================================
# modules/osetupgit.sh — Cài đặt các thiết lập cho repo hiện tại (hooks, ...)
# Được load tự động bởi alias.sh — KHÔNG source trực tiếp file này
#
# Kiến trúc mở rộng:
#   Mỗi hạng mục cài đặt là 1 "action" độc lập:
#     - 1 hàm thực thi: _osg_action_<tên>
#     - 1 dòng đăng ký:  _osg_register_action "<id>" "<label>" "<mô tả>" "_osg_action_<tên>"
#   Muốn thêm hạng mục mới: viết thêm 1 hàm _osg_action_xxx rồi đăng ký ở cuối
#   file này — KHÔNG cần sửa hàm osetupgit() chính, menu tự cập nhật.
#
# Action hiện có:
#   commithook — Cài prepare-commit-msg + post-commit dùng file
#                .git/.git-o-commit-template làm commit message mặc định:
#                  1. Agent / bạn ghi nội dung công việc vào .git/.git-o-commit-template
#                  2. `git commit` (không cần -m) → editor mở sẵn nội dung đó
#                  3. Sau khi commit xong → file tự động được clear (post-commit)
#                     để phiên làm việc kế tiếp ghi nội dung mới vào
#                Chỉ áp dụng cho commit thường (bỏ qua merge/squash/-m có sẵn),
#                không clear ở bước prepare-commit-msg để tránh mất nội dung
#                nếu commit bị hủy giữa chừng.
# =============================================================================

[[ -n "${_O_MODULE_SETUPGIT_LOADED:-}" ]] && return 0
_O_MODULE_SETUPGIT_LOADED=1

# ---------------------------------------------------------------------------
# ĐĂNG KÝ ACTION — mảng song song, KHÔNG cần sửa gì khác khi thêm action mới
# ---------------------------------------------------------------------------
declare -a _OSG_ACTIONS_ID=()
declare -a _OSG_ACTIONS_LABEL=()
declare -a _OSG_ACTIONS_DESC=()
declare -a _OSG_ACTIONS_FUNC=()

function _osg_register_action() {
    _OSG_ACTIONS_ID+=("$1")
    _OSG_ACTIONS_LABEL+=("$2")
    _OSG_ACTIONS_DESC+=("$3")
    _OSG_ACTIONS_FUNC+=("$4")
}

# ---------------------------------------------------------------------------
# HELPER: Parse chuỗi số cách phẩy (giống pattern odeletebranch), trả về
# danh sách số hợp lệ, không trùng
# ---------------------------------------------------------------------------
function _osg_parse_selection() {
    local input="$1"
    local max="$2"
    local -a result=()

    IFS=',' read -ra parts <<< "$input"
    local part
    for part in "${parts[@]}"; do
        local num="${part// /}"
        if ! [[ "$num" =~ ^[0-9]+$ ]]; then
            echo "[setupgit] Giá trị không hợp lệ: '$num'" >&2
            return 1
        fi
        if (( num < 1 || num > max )); then
            echo "[setupgit] Số ngoài phạm vi (1-${max}): $num" >&2
            return 1
        fi
        result+=("$num")
    done

    local seen="" n
    for n in "${result[@]}"; do
        if [[ ! " $seen " =~ " $n " ]]; then
            echo "$n"
            seen+=" $n"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# HELPER: Chèn / cập nhật một block đánh dấu (marker) vào file, giữ nguyên
# phần nội dung khác của file (không phá hook đã có sẵn của người dùng)
#
# $1 = đường dẫn file
# $2 = dòng marker bắt đầu (phải trùng khớp chính xác với dòng đầu của $4)
# $3 = dòng marker kết thúc (phải trùng khớp chính xác với dòng cuối của $4)
# $4 = nội dung block đầy đủ (đã bao gồm marker begin/end ở dòng đầu/cuối)
# ---------------------------------------------------------------------------
function _osg_upsert_block() {
    local file="$1" begin_marker="$2" end_marker="$3" block="$4"
    local tmpfile
    tmpfile=$(mktemp)

    if [[ -f "$file" ]] && grep -qxF "$begin_marker" "$file" 2>/dev/null; then
        local in_block=0
        local wrote_block=0
        local line
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "$begin_marker" ]]; then
                in_block=1
                printf '%s\n' "$block" >> "$tmpfile"
                wrote_block=1
                continue
            fi
            if [[ "$line" == "$end_marker" ]]; then
                in_block=0
                continue
            fi
            [[ "$in_block" == "0" ]] && printf '%s\n' "$line" >> "$tmpfile"
        done < "$file"
        (( wrote_block == 0 )) && printf '%s\n' "$block" >> "$tmpfile"
    else
        if [[ -f "$file" ]]; then
            cat "$file" > "$tmpfile"
            [[ -s "$tmpfile" ]] && printf '\n' >> "$tmpfile"
        else
            printf '#!/usr/bin/env bash\n\n' > "$tmpfile"
        fi
        printf '%s\n' "$block" >> "$tmpfile"
    fi

    mv "$tmpfile" "$file"
    chmod +x "$file"
}

# =============================================================================
# ACTION: commithook
# =============================================================================
function _osg_action_commithook() {
    local hooks_dir
    hooks_dir=$(git rev-parse --git-path hooks 2>/dev/null)

    if [[ -z "$hooks_dir" ]]; then
        echo "  ✗ Không xác định được thư mục hooks (không phải git repo?)" >&2
        return 1
    fi
    mkdir -p "$hooks_dir"

    local template_file
    template_file="$(git rev-parse --git-dir)/.git-o-commit-template"
    local prepare_hook="${hooks_dir}/prepare-commit-msg"
    local post_hook="${hooks_dir}/post-commit"
    local marker_begin="# >>> git-o-alias: setupgit commithook >>>"
    local marker_end="# <<< git-o-alias: setupgit commithook <<<"

    local prepare_block
    read -r -d '' prepare_block <<'EOF' || true
# >>> git-o-alias: setupgit commithook >>>
# Tự động bởi: git setupgit (action: commithook)
# Nếu .git/.git-o-commit-template có nội dung → dùng làm commit message mặc định.
# Chỉ áp dụng cho commit thường (COMMIT_SOURCE rỗng), bỏ qua merge/squash/-m.
# KHÔNG clear ở đây — để post-commit clear sau khi commit thành công, tránh
# mất nội dung nếu commit bị hủy giữa chừng (VD: đóng editor không lưu).
_O_CT_FILE="$(git rev-parse --git-dir)/.git-o-commit-template"
_O_COMMIT_MSG_FILE="$1"
_O_COMMIT_SOURCE="$2"
if [[ -z "$_O_COMMIT_SOURCE" ]] && [[ -f "$_O_CT_FILE" ]] && [[ -s "$_O_CT_FILE" ]]; then
    cat "$_O_CT_FILE" > "$_O_COMMIT_MSG_FILE"
fi
# <<< git-o-alias: setupgit commithook <<<
EOF

    local postcommit_block
    read -r -d '' postcommit_block <<'EOF' || true
# >>> git-o-alias: setupgit commithook >>>
# Tự động bởi: git setupgit (action: commithook)
# Clear nội dung .git/.git-o-commit-template sau khi commit thành công, để phiên
# làm việc kế tiếp (agent hoặc bạn) có thể ghi nội dung mới vào từ đầu.
_O_CT_FILE="$(git rev-parse --git-dir)/.git-o-commit-template"
if [[ -f "$_O_CT_FILE" ]]; then
    : > "$_O_CT_FILE"
fi
# <<< git-o-alias: setupgit commithook <<<
EOF

    echo "  → Cài prepare-commit-msg ..."
    _osg_upsert_block "$prepare_hook" "$marker_begin" "$marker_end" "$prepare_block"
    echo "    ✓ ${prepare_hook}"

    echo "  → Cài post-commit ..."
    _osg_upsert_block "$post_hook" "$marker_begin" "$marker_end" "$postcommit_block"
    echo "    ✓ ${post_hook}"

    [[ -f "$template_file" ]] || touch "$template_file"
    echo "  ✓ Đã đảm bảo có file: ${template_file}"

    echo ""
    echo "  ✓ Hoàn tất. Cách dùng:"
    echo "    1. Ghi nội dung công việc vào : ${template_file}"
    echo "    2. Chạy                       : git commit   (không cần -m)"
    echo "    3. Sau khi commit xong        : ${template_file} tự động được clear"
    return 0
}

# =============================================================================
# PUBLIC: osetupgit — menu chọn 1 hoặc nhiều hạng mục để cài đặt
# =============================================================================
function osetupgit() {
    if ! git rev-parse --git-dir &>/dev/null 2>&1; then
        echo "[setupgit] ERROR: Không phải git repo." >&2
        return 1
    fi

    local max="${#_OSG_ACTIONS_ID[@]}"
    if (( max == 0 )); then
        echo "[setupgit] Chưa có hạng mục cài đặt nào được đăng ký." >&2
        return 1
    fi

    echo ""
    echo "  ┌─────────────────────────────────────────────────────────"
    echo "  │  git setupgit — Cài đặt cho repo hiện tại"
    echo "  └─────────────────────────────────────────────────────────"
    echo ""
    echo "  Hạng mục có thể cài đặt:"
    echo ""

    local i
    for (( i=0; i<max; i++ )); do
        printf "    [%d]  %-12s  %s\n" "$((i+1))" "${_OSG_ACTIONS_LABEL[$i]}" "${_OSG_ACTIONS_DESC[$i]}"
    done

    echo ""
    echo "    [a]  Tất cả"
    echo "    [0]  Hủy"
    echo ""
    echo "  Chọn nhiều hạng mục cách nhau bằng dấu phẩy, ví dụ: 1,2"
    echo ""

    local choice
    read -r -p "  Chọn hạng mục [0-${max}/a]: " choice
    choice="${choice,,}"

    if [[ -z "$choice" || "$choice" == "0" ]]; then
        echo "  Hủy."
        echo ""
        return 0
    fi

    local -a to_run=()

    if [[ "$choice" == "a" ]]; then
        for (( i=0; i<max; i++ )); do to_run+=("$i"); done
    else
        local parsed
        if ! parsed=$(_osg_parse_selection "$choice" "$max"); then
            echo "" >&2
            echo "  Lựa chọn không hợp lệ." >&2
            return 1
        fi
        local n
        while IFS= read -r n; do
            [[ -z "$n" ]] && continue
            to_run+=("$((n - 1))")
        done <<< "$parsed"
    fi

    if [[ ${#to_run[@]} -eq 0 ]]; then
        echo "  Không có hạng mục nào được chọn."
        echo ""
        return 0
    fi

    echo ""
    local has_error=0
    for i in "${to_run[@]}"; do
        echo "  ── ${_OSG_ACTIONS_LABEL[$i]} ──────────────────────────────"
        if ! "${_OSG_ACTIONS_FUNC[$i]}"; then
            has_error=1
        fi
        echo ""
    done

    if (( has_error )); then
        echo "  ⚠  Một số hạng mục cài đặt thất bại, xem log ở trên."
    else
        echo "  [setupgit] Done."
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# ĐĂNG KÝ CÁC ACTION HIỆN CÓ — thêm action mới thì thêm 1 dòng ở đây
# ---------------------------------------------------------------------------
_osg_register_action \
    "commithook" \
    "commithook" \
    "Commit message tự động từ .git/.git-o-commit-template, tự clear sau commit" \
    "_osg_action_commithook"

# (Thêm action mới phía dưới theo cùng pattern, ví dụ:)
# _osg_register_action "xxx" "xxx" "Mô tả hạng mục" "_osg_action_xxx"