// lib/prompt.js — Các helper tương tác CLI (menu, input, confirm)
// Dùng readline built-in, không có dependency ngoài.

"use strict";

const readline = require("readline");

function createRl() {
  return readline.createInterface({ input: process.stdin, output: process.stdout });
}

/** Hỏi một câu, trả về Promise<string> */
function ask(question, defaultVal = "") {
  return new Promise((resolve) => {
    const rl = createRl();
    const prompt = defaultVal ? `${question} [${defaultVal}]: ` : `${question}: `;
    rl.question(prompt, (ans) => {
      rl.close();
      resolve(ans.trim() || defaultVal);
    });
  });
}

/** Confirm y/n, trả về Promise<boolean> */
async function confirm(question, defaultYes = true) {
  const hint = defaultYes ? "Y/n" : "y/N";
  const ans = await ask(`${question} [${hint}]`);
  if (!ans) return defaultYes;
  return ans.toLowerCase().startsWith("y");
}

/**
 * Confirm y/n hoặc nhập số để chạy lệnh tiếp.
 * Trả về:
 *   true  — yes (tiếp tục vòng lặp)
 *   false — no  (thoát)
 *   number — số lệnh cần chạy tiếp (trực tiếp)
 */
async function confirmOrNumber(question, maxNum, defaultYes = true) {
  const hint = defaultYes ? "Y/n/số tiếp" : "y/N/số tiếp";
  while (true) {
    const ans = await ask(`${question} [${hint}]`);
    if (!ans) return defaultYes;
    const trimmed = ans.trim();
    const n = parseInt(trimmed, 10);
    if (!isNaN(n) && n >= 1 && n <= maxNum) return n;
    if (/^[yY]/.test(trimmed)) return true;
    if (/^[nN]/.test(trimmed)) return false;
    console.log(`  Nhập Y/n hoặc số từ 1 đến ${maxNum}.`);
  }
}

/**
 * Hiển thị menu + hỏi chọn số.
 * items: [{ label: string }]
 * Trả về index (0-based) đã chọn.
 * Nếu có option 0=Thoát, trả về -1.
 */
async function selectMenu(title, items, { allowCancel = true } = {}) {
  console.log("");
  console.log(`  ┌${"─".repeat(60)}`);
  console.log(`  │  ${title}`);
  console.log(`  ├${"─".repeat(60)}`);
  items.forEach((item, i) => {
    console.log(`  │  [${i + 1}]  ${item.label}`);
  });
  if (allowCancel) console.log("  │  [0]  Hủy / Quay lại");
  console.log(`  └${"─".repeat(60)}`);
  console.log("");

  const max = items.length;
  while (true) {
    const ans = await ask(`  Chọn [${allowCancel ? "0-" : "1-"}${max}]`);

    // Số
    const n = parseInt(ans, 10);
    if (allowCancel && n === 0) return -1;
    if (n >= 1 && n <= max) return n - 1;

    // Email → lấy username, lọc ký tự đặc biệt, tìm gần nhất
    if (ans.includes("@")) {
      const emailUser = ans.split("@")[0];
      const emailClean = emailUser.replace(/[^a-zA-Z0-9]/g, "");
      if (emailClean) {
        const matches = [];
        const lower = emailClean.toLowerCase();
        for (let i = 0; i < max; i++) {
          if (items[i].label.toLowerCase().includes(lower)) matches.push(i);
        }
        if (matches.length === 1) {
          console.log(`  → Email → [${matches[0] + 1}] ${items[matches[0]].label}`);
          return matches[0];
        }
        if (matches.length > 1) {
          console.log(`  Email '${ans}' khớp ${matches.length} mục:`);
          for (const mi of matches) console.log(`    [${mi + 1}] ${items[mi].label}`);
          console.log("");
          continue;
        }
      }
    }

    // Tìm theo tên (exact → substring)
    const matches = [];
    const lower = ans.toLowerCase();
    for (let i = 0; i < max; i++) {
      const label = items[i].label.toLowerCase();
      if (label === lower) { matches.length = 0; matches.push(i); break; }
      if (label.includes(lower)) matches.push(i);
    }

    if (matches.length === 1) {
      console.log(`  → Chọn: [${matches[0] + 1}] ${items[matches[0]].label}`);
      return matches[0];
    }
    if (matches.length > 1) {
      const showLimit = 20;
      if (matches.length <= showLimit) {
        console.log(`  Có ${matches.length} kết quả:`);
        for (const mi of matches) console.log(`    [${mi + 1}] ${items[mi].label}`);
      } else {
        console.log(`  Từ khóa '${ans}' quá ngắn (${matches.length} kết quả). Gõ thêm ký tự.`);
      }
      console.log("");
      continue;
    }

    console.log(`  Nhập số (${allowCancel ? "0-" : ""}1-${max}) hoặc tên/email.`);
  }
}

/**
 * Multi-select: hiển thị danh sách có đánh số, cho phép chọn nhiều items.
 *
 * @param {string} title        — Tiêu đề
 * @param {Array}  items        — Mảng item, mỗi item có { label: string }
 * @param {object} opts
 *   allowAll  {boolean}  — Có option "all" không (default: true)
 *   minSelect {number}   — Tối thiểu phải chọn bao nhiêu (default: 1)
 *
 * @returns Promise<number[]>  — Mảng index 0-based của các item đã chọn.
 *                               Trả về [] nếu user hủy (nhập 0).
 *
 * Cú pháp nhập của user:
 *   all         — chọn tất cả
 *   1           — chọn 1 item
 *   1,3,5       — chọn nhiều items (cách nhau bằng dấu phẩy)
 *   1-5         — chọn dải (range)
 *   1,3-5,7     — kết hợp
 *   0           — hủy
 */
async function askMultiSelect(title, items, { allowAll = true, minSelect = 1 } = {}) {
  if (items.length === 0) return [];

  console.log("");
  console.log(`  ┌${"─".repeat(60)}`);
  console.log(`  │  ${title}`);
  console.log(`  ├${"─".repeat(60)}`);
  items.forEach((item, i) => {
    console.log(`  │  [${String(i + 1).padStart(2)}]  ${item.label}`);
  });
  console.log("  │");
  if (allowAll) {
    console.log("  │  Cú pháp: all | 1 | 1,3,5 | 1-5 | 1,3-5,7");
  } else {
    console.log("  │  Cú pháp: 1 | 1,3,5 | 1-5 | 1,3-5,7");
  }
  console.log("  │  [0]  Hủy / Quay lại");
  console.log(`  └${"─".repeat(60)}`);
  console.log("");

  const max = items.length;

  while (true) {
    const raw = await ask(`  Chọn [0-${max}]`);
    const trimmed = raw.trim().toLowerCase();

    if (trimmed === "0") return [];

    if (allowAll && trimmed === "all") {
      return items.map((_, i) => i);
    }

    // Parse "1,3-5,7" dạng
    const indices = new Set();
    const parts = trimmed.split(",");
    let parseError = false;

    for (const part of parts) {
      const p = part.trim();
      if (!p) continue;

      const rangeMatch = p.match(/^(\d+)-(\d+)$/);
      if (rangeMatch) {
        const from = parseInt(rangeMatch[1], 10);
        const to = parseInt(rangeMatch[2], 10);
        if (isNaN(from) || isNaN(to) || from < 1 || to > max || from > to) {
          parseError = true;
          break;
        }
        for (let i = from; i <= to; i++) indices.add(i - 1);
      } else {
        const n = parseInt(p, 10);
        if (isNaN(n) || n < 1 || n > max) {
          parseError = true;
          break;
        }
        indices.add(n - 1);
      }
    }

    if (parseError || indices.size === 0) {
      console.log(`  Nhập hợp lệ (ví dụ: all, 1, 1,3, 2-5, 1,3-5) hoặc 0 để hủy.`);
      continue;
    }

    if (indices.size < minSelect) {
      console.log(`  Cần chọn ít nhất ${minSelect} item.`);
      continue;
    }

    return Array.from(indices).sort((a, b) => a - b);
  }
}

/**
 * Hiển thị danh sách có index để chọn nhiều lần (không loop — chỉ chọn 1 lần).
 * Tiện dụng cho danh sách repo, secret, v.v.
 */
async function selectList(title, items, labelFn) {
  return selectMenu(
    title,
    items.map((it) => ({ label: labelFn(it) })),
  );
}

/** Hỏi nhập đường dẫn file (có kiểm tra tồn tại) */
async function askFilePath(question) {
  const path = require("path");
  const fs = require("fs");

  while (true) {
    const raw = await ask(question);
    if (!raw) return null;
    const resolved = raw.startsWith("~") ? path.join(require("os").homedir(), raw.slice(1)) : path.resolve(raw);
    if (fs.existsSync(resolved)) return resolved;
    console.log(`  ✗ Không tìm thấy file: ${resolved}`);
  }
}

/** Đọc multiline từ stdin cho đến khi gặp dòng rỗng (Enter 2 lần) */
function askMultiline(prompt) {
  return new Promise((resolve) => {
    console.log(`  ${prompt} (nhập xong bấm Enter 2 lần):`);
    const rl = createRl();
    const lines = [];
    rl.on("line", (line) => {
      if (line === "" && lines.length > 0 && lines[lines.length - 1] === "") {
        rl.close();
      } else {
        lines.push(line);
      }
    });
    rl.on("close", () => resolve(lines.join("\n").trimEnd()));
  });
}

module.exports = { ask, confirm, confirmOrNumber, selectMenu, selectList, askFilePath, askMultiline, askMultiSelect };
