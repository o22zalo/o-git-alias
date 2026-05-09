// services/npm/index.js — Subcommand `ocli npm`
// Flow: quét package.json (+ tùy chọn .bat / .cmd) trong cwd và thư mục con
//       → hiển thị grouped menu → chạy lệnh với stdio inherit → hỏi tiếp hay thoát
//
// Args hỗ trợ:
//   --bat   Quét thêm file .bat trong toàn bộ cây thư mục
//   --cmd   Quét thêm file .cmd trong toàn bộ cây thư mục
//
// Ví dụ:
//   ocli npm
//   ocli npm --bat
//   ocli npm --bat --cmd

'use strict';

const fs              = require('fs');
const path            = require('path');
const { spawnSync }   = require('child_process');
const { ask, confirm } = require('../../lib/prompt');

const LOG       = '[npm]';
const MAX_DEPTH = 5;

// Thư mục bỏ qua khi quét — tránh quét sâu vào output/cache
const SKIP_DIRS = new Set([
  'node_modules', '.git', '.next', '.nuxt',
  'dist', 'build', 'out', 'coverage',
  '.cache', '.turbo', '.parcel-cache',
  '__pycache__', '.venv',
]);

// ─────────────────────────────────────────────────────────────────
// SCAN helpers — quét file đệ quy, bỏ qua SKIP_DIRS
// ─────────────────────────────────────────────────────────────────

/**
 * Quét đệ quy từ rootDir, trả về mảng đường dẫn tuyệt đối của file
 * thoả matchFn(filename) == true.
 */
function scanFiles(rootDir, matchFn) {
  const results = [];

  function walk(dir, depth) {
    if (depth > MAX_DEPTH) return;
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return; // Không có quyền đọc thư mục → bỏ qua
    }
    for (const entry of entries) {
      if (SKIP_DIRS.has(entry.name)) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full, depth + 1);
      } else if (entry.isFile() && matchFn(entry.name)) {
        results.push(full);
      }
    }
  }

  walk(rootDir, 0);
  return results;
}

/**
 * Parse scripts từ package.json.
 * Trả về { name, entries } — entries là mảng [scriptName, scriptCmd].
 */
function parsePackageScripts(filePath) {
  try {
    const raw = fs.readFileSync(filePath, 'utf8');
    const pkg = JSON.parse(raw);
    return {
      name:    pkg.name || '',
      version: pkg.version || '',
      entries: Object.entries(pkg.scripts || {}),
    };
  } catch {
    return { name: '', version: '', entries: [] };
  }
}

// ─────────────────────────────────────────────────────────────────
// BUILD ITEMS — tổng hợp danh sách lệnh chạy được
// ─────────────────────────────────────────────────────────────────

/**
 * Trả về mảng item object. Mỗi item đại diện cho 1 lệnh có thể chạy.
 *
 * Item shape:
 *   {
 *     type        : 'npm' | 'bat' | 'cmd'
 *     group       : string   — nhãn nhóm hiển thị (vd: "📦 package.json (myapp)")
 *     groupKey    : string   — key để gom nhóm (đường dẫn tuyệt đối hoặc sentinel)
 *     displayName : string   — cột tên trong menu
 *     displayCmd  : string   — cột preview command trong menu
 *     runDir      : string   — working directory khi chạy
 *     scriptName  : string   — (npm) tên script | (bat/cmd) basename file
 *     scriptCmd   : string   — (npm) command string | (bat/cmd) đường dẫn tuyệt đối
 *     _menuIdx    : number   — gán lúc render menu
 *   }
 */
function buildItems(cwd, includeBat, includeCmd) {
  const items = [];

  // ── npm scripts từ tất cả package.json ───────────────────────────
  const pkgFiles = scanFiles(cwd, (n) => n === 'package.json');
  // Sắp xếp: package.json ở root trước, rồi theo thứ tự alphabet
  pkgFiles.sort((a, b) => {
    const aDepth = path.relative(cwd, a).split(path.sep).length;
    const bDepth = path.relative(cwd, b).split(path.sep).length;
    if (aDepth !== bDepth) return aDepth - bDepth;
    return a.localeCompare(b);
  });

  for (const pkgFile of pkgFiles) {
    const rel    = path.relative(cwd, pkgFile) || 'package.json';
    const pkgDir = path.dirname(pkgFile);
    const { name, version, entries } = parsePackageScripts(pkgFile);
    if (entries.length === 0) continue;

    let groupLabel = `📦 ${rel}`;
    if (name) groupLabel += `  (${name}${version ? ' ' + version : ''})`;

    for (const [scriptName, scriptCmd] of entries) {
      items.push({
        type:        'npm',
        group:       groupLabel,
        groupKey:    pkgFile,
        displayName: scriptName,
        displayCmd:  scriptCmd,
        runDir:      pkgDir,
        scriptName,
        scriptCmd,
      });
    }
  }

  // ── .bat files ────────────────────────────────────────────────────
  if (includeBat) {
    const batFiles = scanFiles(cwd, (n) => n.toLowerCase().endsWith('.bat'));
    batFiles.sort();
    for (const batFile of batFiles) {
      const rel = path.relative(cwd, batFile);
      items.push({
        type:        'bat',
        group:       '🔧 .bat files',
        groupKey:    '__bat__',
        displayName: path.basename(batFile),
        displayCmd:  rel,
        runDir:      path.dirname(batFile),
        scriptName:  path.basename(batFile),
        scriptCmd:   batFile,
      });
    }
  }

  // ── .cmd files ────────────────────────────────────────────────────
  if (includeCmd) {
    const cmdFiles = scanFiles(cwd, (n) => n.toLowerCase().endsWith('.cmd'));
    cmdFiles.sort();
    for (const cmdFile of cmdFiles) {
      const rel = path.relative(cwd, cmdFile);
      items.push({
        type:        'cmd',
        group:       '🔧 .cmd files',
        groupKey:    '__cmd__',
        displayName: path.basename(cmdFile),
        displayCmd:  rel,
        runDir:      path.dirname(cmdFile),
        scriptName:  path.basename(cmdFile),
        scriptCmd:   cmdFile,
      });
    }
  }

  return items;
}

// ─────────────────────────────────────────────────────────────────
// DISPLAY — grouped menu với header mỗi nhóm
// ─────────────────────────────────────────────────────────────────

const MENU_WIDTH = 74;

/**
 * In grouped menu ra console, gán _menuIdx cho từng item.
 * Trả về tổng số item (để validate input sau).
 */
function printGroupedMenu(items) {
  // Gom nhóm giữ thứ tự xuất hiện
  const groupOrder = [];
  const groupMap   = new Map(); // groupKey → { label, items[] }

  for (const item of items) {
    if (!groupMap.has(item.groupKey)) {
      groupMap.set(item.groupKey, { label: item.group, items: [] });
      groupOrder.push(item.groupKey);
    }
    groupMap.get(item.groupKey).items.push(item);
  }

  console.log('');
  console.log(`  ┌${'─'.repeat(MENU_WIDTH)}`);
  console.log('  │  Chọn lệnh để chạy');
  console.log(`  ├${'─'.repeat(MENU_WIDTH)}`);

  let idx = 1;
  for (const key of groupOrder) {
    const { label, items: groupItems } = groupMap.get(key);
    console.log('  │');
    console.log(`  │  ${label}`);
    console.log(`  │  ${'╌'.repeat(MENU_WIDTH - 2)}`);

    for (const item of groupItems) {
      item._menuIdx = idx;

      // Cột tên: 22 ký tự
      const nameCol = item.displayName.length > 22
        ? item.displayName.slice(0, 20) + '..'
        : item.displayName.padEnd(22);

      // Cột command preview: phần còn lại
      const maxCmdLen = MENU_WIDTH - 10 - 22;
      const cmdPreview = item.displayCmd.length > maxCmdLen
        ? item.displayCmd.slice(0, maxCmdLen - 3) + '...'
        : item.displayCmd;

      const idxStr = String(idx).padStart(2);
      console.log(`  │    [${idxStr}]  ${nameCol}  ${cmdPreview}`);
      idx++;
    }
  }

  console.log('  │');
  console.log('  │    [ 0]  Thoát');
  console.log(`  └${'─'.repeat(MENU_WIDTH)}`);
  console.log('');

  return items.length;
}

// ─────────────────────────────────────────────────────────────────
// INPUT — hỏi số lựa chọn
// ─────────────────────────────────────────────────────────────────

async function askChoice(items) {
  const max = items.length;
  while (true) {
    const ans = await ask(`  Chọn [0-${max}]`);
    const trimmed = ans.trim();
    if (trimmed === '0' || trimmed === '') return null;
    const n = parseInt(trimmed, 10);
    if (!isNaN(n) && n >= 1 && n <= max) {
      // Tìm item với _menuIdx tương ứng
      return items.find((item) => item._menuIdx === n) || null;
    }
    console.log(`  Nhập số từ 0 đến ${max}.`);
  }
}

// ─────────────────────────────────────────────────────────────────
// EXECUTE — chạy lệnh với stdio inherit
// ─────────────────────────────────────────────────────────────────

function executeItem(item) {
  let cmd, cmdArgs;

  if (item.type === 'npm') {
    // npm run <script> — dùng shell: true để tương thích npm.cmd trên Windows
    cmd     = 'npm';
    cmdArgs = ['run', item.scriptName];
  } else {
    // .bat / .cmd — chỉ chạy trên Windows
    if (process.platform !== 'win32') {
      console.log(`${LOG} ⚠  File ${item.type.toUpperCase()} chỉ chạy được trên Windows.`);
      return;
    }
    cmd     = 'cmd';
    cmdArgs = ['/c', item.scriptCmd];
  }

  const runLabel = item.type === 'npm'
    ? `npm run ${item.scriptName}`
    : item.displayCmd;

  const relDir = path.relative(process.cwd(), item.runDir) || '.';

  console.log(`\n${LOG} Lệnh    : ${runLabel}`);
  console.log(`${LOG} Thư mục : ${relDir}`);
  console.log(`\n${'─'.repeat(60)}\n`);

  const result = spawnSync(cmd, cmdArgs, {
    stdio:  'inherit',    // output thẳng ra terminal — không buffer
    cwd:    item.runDir,
    shell:  true,         // cho phép tìm npm.cmd, cmd.exe cross-platform
    env:    process.env,
  });

  console.log(`\n${'─'.repeat(60)}`);

  const exitCode = result.status ?? (result.error ? 1 : 0);
  if (exitCode === 0) {
    console.log(`${LOG} ✓ Hoàn thành (exit 0)`);
  } else {
    if (result.error) {
      console.log(`${LOG} ✗ Lỗi khởi chạy: ${result.error.message}`);
    } else {
      console.log(`${LOG} ✗ Exit code: ${exitCode}`);
    }
  }
}

// ─────────────────────────────────────────────────────────────────
// SUMMARY — in tóm tắt những gì tìm thấy
// ─────────────────────────────────────────────────────────────────

function printScanSummary(items, cwd, includeBat, includeCmd) {
  const pkgKeys   = new Set(items.filter((i) => i.type === 'npm').map((i) => i.groupKey));
  const npmCount  = items.filter((i) => i.type === 'npm').length;
  const batCount  = items.filter((i) => i.type === 'bat').length;
  const cmdCount  = items.filter((i) => i.type === 'cmd').length;

  const parts = [];
  if (pkgKeys.size > 0) parts.push(`${pkgKeys.size} package.json (${npmCount} script)`);
  if (batCount > 0)     parts.push(`${batCount} file .bat`);
  if (cmdCount > 0)     parts.push(`${cmdCount} file .cmd`);

  console.log(`${LOG} Tìm thấy: ${parts.join('  │  ')}`);

  if (!includeBat || !includeCmd) {
    const hints = [];
    if (!includeBat) hints.push('--bat');
    if (!includeCmd) hints.push('--cmd');
    if (hints.length > 0) {
      console.log(`${LOG} Gợi ý: thêm ${hints.join(' ')} để quét thêm loại file đó`);
    }
  }
}

// ─────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────

async function run(args = []) {
  const includeBat = args.includes('--bat') || args.includes('-bat');
  const includeCmd = args.includes('--cmd') || args.includes('-cmd');
  const cwd        = process.cwd();

  console.log(`\n${LOG} Đang quét: ${cwd}`);

  const items = buildItems(cwd, includeBat, includeCmd);

  if (items.length === 0) {
    console.log(`${LOG} Không tìm thấy lệnh nào.`);
    console.log(`${LOG} Kiểm tra:`);
    console.log(`${LOG}   1. Thư mục có file package.json với mục "scripts" không?`);
    if (!includeBat) console.log(`${LOG}   2. Thêm --bat để quét file .bat`);
    if (!includeCmd) console.log(`${LOG}   3. Thêm --cmd để quét file .cmd`);
    return;
  }

  printScanSummary(items, cwd, includeBat, includeCmd);

  // ── Vòng lặp chính ────────────────────────────────────────────────
  while (true) {
    printGroupedMenu(items);
    const chosen = await askChoice(items);
    if (!chosen) break;

    executeItem(chosen);

    console.log('');
    const cont = await confirm('  Chạy tiếp lệnh khác?', true);
    if (!cont) break;
  }
}

module.exports = { run };
