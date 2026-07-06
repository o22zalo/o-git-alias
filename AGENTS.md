# Agent Guidelines & Rules

All AI agents working on this repository must adhere to the following rules.

## Commit Message Auto-Preparation

To streamline the code review and commit workflow for the developer, the agent must prepare the commit message at the end of each session.

### Rules:

1. **Session Completion:**
   - Summarize only the changes made in the session that have NOT been committed yet. Do NOT include changes from previous commits that have already been finalized.
   - Write the commit summary directly to `.vstool-commit-template.txt`. Do NOT commit the changes; let the user review and commit them manually.
   - **Phải ghi rõ cách áp dụng thay đổi** (xem phần [Applying Code Changes](#applying-code-changes) bên dưới) vào cuối commit message, dưới dạng hướng dẫn ngắn gọn cho developer.

## Git Hooks (Auto-Load Commit Message)

Các hooks trong `.githooks/` giúp tự động hoá việc dùng commit message đã soạn sẵn:

| Hook | Chức năng |
|------|-----------|
| `prepare-commit-msg` | Tự động nạp nội dung `.vstool-commit-template.txt` vào commit message khi chạy `git commit` (mở editor) |
| `post-commit` | Xoá `.vstool-commit-template.txt` sau khi commit thành công |

### Kích hoạt

```bash
git config core.hooksPath .githooks
```

Sau đó chỉ cần chạy `git commit` — message từ template sẽ tự động xuất hiện trong editor.

## VS Code Integration (Commit UI)

VS Code dùng `commit.template` để hiển thị message trong ô commit của SCM view:

```bash
git config commit.template .vstool-commit-template.txt
```

Sau đó, mỗi khi agent ghi message vào `.vstool-commit-template.txt`, VS Code sẽ tự động load vào ô commit.

## Applying Code Changes

Quy trình áp dụng thay đổi từ agent:

1. **Review** — chạy `git diff` để xem thay đổi
2. **Stage** — `git add <file>` hoặc `git add -A`
3. **Commit** — `git commit` (nếu đã bật hooks, message sẽ tự nạp; nếu dùng VS Code, message hiển thị sẵn trong ô commit)
4. **Push** — `git push`
