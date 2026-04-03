// services/addfiles/index.js — Subcommand `ocli addfiles`
// Flow: nhận input file/zip → staging vào ocli-addfiles-temp → parse header path trong 3 dòng đầu → ghi/move file vào cwd

'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const { askFilePath, selectMenu } = require('../../lib/prompt');
const { spawn, commandExists } = require('../../lib/shell');

const LOG = '[addfiles]';
const TEMP_DIR_NAME = 'ocli-addfiles-temp';

function ensureCleanTempDir(cwd) {
  const tempRoot = path.resolve(cwd, TEMP_DIR_NAME);
  fs.rmSync(tempRoot, { recursive: true, force: true });
  fs.mkdirSync(tempRoot, { recursive: true });
  return tempRoot;
}

function resolveInputFromArgs(args) {
  if (!Array.isArray(args) || args.length === 0) return null;
  const raw = args[0];
  if (!raw) return null;

  const normalized = raw.startsWith('~')
    ? path.join(os.homedir(), raw.slice(1))
    : raw;

  const resolved = path.resolve(process.cwd(), normalized);
  return fs.existsSync(resolved) ? resolved : null;
}

async function askInputPathInteractively() {
  console.log(`${LOG} Không tìm thấy path hợp lệ từ args. Mời nhập lại đường dẫn file/zip.`);
  const inputPath = await askFilePath('Nhập đường dẫn file hoặc zip cần xử lý');
  return inputPath;
}

function isZipFile(filePath) {
  if (!fs.statSync(filePath).isFile()) return false;
  if (path.extname(filePath).toLowerCase() === '.zip') return true;

  try {
    const fd = fs.openSync(filePath, 'r');
    const buf = Buffer.alloc(4);
    fs.readSync(fd, buf, 0, 4, 0);
    fs.closeSync(fd);
    return buf[0] === 0x50 && buf[1] === 0x4b;
  } catch {
    return false;
  }
}

function extractZipToTemp(zipPath, tempRoot) {
  const unzipDir = path.join(tempRoot, 'unzipped');
  fs.mkdirSync(unzipDir, { recursive: true });

  if (process.platform === 'win32') {
    const psScript = [
      '$ErrorActionPreference = "Stop"',
      `Expand-Archive -LiteralPath '${zipPath.replace(/'/g, "''")}' -DestinationPath '${unzipDir.replace(/'/g, "''")}' -Force`,
    ].join('; ');
    const r = spawn('powershell', ['-NoProfile', '-Command', psScript]);
    if (!r.ok) {
      throw new Error(`${LOG} Giải nén zip thất bại bằng PowerShell: ${r.stderr || 'unknown error'}`);
    }
    return unzipDir;
  }

  if (commandExists('unzip')) {
    const r = spawn('unzip', ['-o', zipPath, '-d', unzipDir]);
    if (!r.ok) {
      throw new Error(`${LOG} Giải nén zip thất bại bằng unzip: ${r.stderr || 'unknown error'}`);
    }
    return unzipDir;
  }

  if (commandExists('tar')) {
    const r = spawn('tar', ['-xf', zipPath, '-C', unzipDir]);
    if (!r.ok) {
      throw new Error(`${LOG} Giải nén zip thất bại bằng tar: ${r.stderr || 'unknown error'}`);
    }
    return unzipDir;
  }

  throw new Error(`${LOG} Không tìm thấy công cụ giải nén zip (cần unzip/tar hoặc PowerShell).`);
}

function stageSingleFile(inputFilePath, tempRoot) {
  const stagedPath = path.join(tempRoot, path.basename(inputFilePath));
  fs.copyFileSync(inputFilePath, stagedPath);
  return tempRoot;
}

function walkFiles(rootDir) {
  const out = [];

  function walk(current) {
    const entries = fs.readdirSync(current, { withFileTypes: true });
    for (const entry of entries) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile()) out.push(full);
    }
  }

  walk(rootDir);
  return out;
}

function collectPathCandidates(lines) {
  const candidates = [];

  for (const line of lines) {
    const m1 = line.match(/^\s*\/\/\s*(?:path|file)\s*:\s*(.+?)\s*$/i);
    if (m1 && m1[1]) {
      candidates.push(m1[1]);
      continue;
    }

    const m2 = line.match(/^\s*\/\/\s*([A-Za-z0-9_./\\-]+\.[A-Za-z0-9_]+)\s*$/);
    if (m2 && m2[1]) {
      candidates.push(m2[1]);
    }
  }

  return [...new Set(candidates)];
}

function sanitizeRelativePath(p) {
  const stripped = p.trim().replace(/^['"“”‘’]|['"“”‘’]$/g, '');
  return stripped.replace(/\\/g, '/').split('/').filter(Boolean).join(path.sep);
}

function safeResolveUnderCwd(cwd, relPath) {
  const finalPath = path.resolve(cwd, relPath);
  const rel = path.relative(cwd, finalPath);
  if (rel.startsWith('..') || path.isAbsolute(rel)) return null;
  return finalPath;
}

function getFileStatsIfExists(filePath) {
  if (!fs.existsSync(filePath)) return null;
  const content = fs.readFileSync(filePath, 'utf8');
  return {
    bytes: Buffer.byteLength(content, 'utf8'),
    chars: content.length,
  };
}

async function selectCandidateIfNeeded(filePath, candidates) {
  if (candidates.length === 0) return null;
  if (candidates.length === 1) return candidates[0];

  const idx = await selectMenu(
    `File ${path.basename(filePath)} có nhiều path trong 3 dòng đầu. Chọn path để ghi`,
    candidates.map((c) => ({ label: c }))
  );

  if (idx === -1) return null;
  return candidates[idx];
}

function formatDelta(oldVal, newVal) {
  const delta = newVal - oldVal;
  const sign = delta >= 0 ? '+' : '';
  return `${oldVal} -> ${newVal} (${sign}${delta})`;
}

async function processStagedFiles(stagingRoot, cwd) {
  const files = walkFiles(stagingRoot);
  const report = {
    total: files.length,
    written: [],
    created: [],
    updated: [],
    skipped: [],
  };

  for (const filePath of files) {
    const relativeFromStage = path.relative(stagingRoot, filePath);

    let content;
    try {
      content = fs.readFileSync(filePath, 'utf8');
    } catch (err) {
      report.skipped.push({
        source: relativeFromStage,
        reason: `Không đọc được UTF-8: ${err.message}`,
      });
      continue;
    }

    const lines = content.replace(/\r\n/g, '\n').split('\n');
    const first3 = lines.slice(0, 3);
    const candidates = collectPathCandidates(first3);

    let targetPath = null;
    let mode = 'fallback-move';

    const selected = await selectCandidateIfNeeded(filePath, candidates);
    if (selected) {
      const rel = sanitizeRelativePath(selected);
      const resolved = safeResolveUnderCwd(cwd, rel);
      if (!resolved) {
        report.skipped.push({
          source: relativeFromStage,
          reason: `Path trong header không an toàn/ra ngoài cwd: ${selected}`,
        });
        continue;
      }
      targetPath = resolved;
      mode = 'header-path';
    } else if (candidates.length > 1 && !selected) {
      report.skipped.push({
        source: relativeFromStage,
        reason: 'Có nhiều path candidate nhưng người dùng hủy chọn.',
      });
      continue;
    }

    if (!targetPath) {
      const fallback = safeResolveUnderCwd(cwd, relativeFromStage);
      if (!fallback) {
        report.skipped.push({
          source: relativeFromStage,
          reason: 'Không resolve được path fallback an toàn từ ocli-addfiles-temp về cwd.',
        });
        continue;
      }
      targetPath = fallback;
    }

    const before = getFileStatsIfExists(targetPath);
    fs.mkdirSync(path.dirname(targetPath), { recursive: true });

    try {
      if (mode === 'fallback-move') {
        fs.renameSync(filePath, targetPath);
      } else {
        fs.writeFileSync(targetPath, content, 'utf8');
      }
    } catch (err) {
      report.skipped.push({
        source: relativeFromStage,
        reason: `Ghi/move thất bại: ${err.message}`,
      });
      continue;
    }

    const after = getFileStatsIfExists(targetPath);
    const item = {
      source: relativeFromStage,
      target: path.relative(cwd, targetPath) || path.basename(targetPath),
      mode,
      size: formatDelta(before ? before.bytes : 0, after ? after.bytes : 0),
      chars: formatDelta(before ? before.chars : 0, after ? after.chars : 0),
      status: before ? 'updated' : 'created',
    };

    report.written.push(item);
    if (before) report.updated.push(item);
    else report.created.push(item);
  }

  return report;
}

function printReport(report, tempRoot) {
  console.log('');
  console.log(`${LOG} ===== Tổng kết xử lý =====`);
  console.log(`${LOG} Tổng file trong staging: ${report.total}`);
  console.log(`${LOG} Ghi/move thành công: ${report.written.length}`);
  console.log(`${LOG}  - Tạo mới: ${report.created.length}`);
  console.log(`${LOG}  - Cập nhật: ${report.updated.length}`);
  console.log(`${LOG} Không thỏa / lỗi: ${report.skipped.length}`);

  if (report.written.length > 0) {
    console.log('');
    console.log(`${LOG} Danh sách file ghi thành công:`);
    report.written.forEach((it, idx) => {
      console.log(`  ${idx + 1}. [${it.status}] ${it.source} -> ${it.target} (${it.mode})`);
      console.log(`     bytes: ${it.size}`);
      console.log(`     chars: ${it.chars}`);
    });
  }

  if (report.skipped.length > 0) {
    console.log('');
    console.log(`${LOG} Danh sách file chưa xử lý được (giữ lại để xử lý tay):`);
    report.skipped.forEach((it, idx) => {
      console.log(`  ${idx + 1}. ${it.source}`);
      console.log(`     reason: ${it.reason}`);
    });
    console.log(`${LOG} Bạn có thể mở lại staging tại: ${tempRoot}`);
  }

  console.log(`${LOG} =========================`);
  console.log('');
}

async function run(args = []) {
  const cwd = process.cwd();
  const inputPath = resolveInputFromArgs(args) || await askInputPathInteractively();

  if (!inputPath) {
    console.log(`${LOG} Không có input file hợp lệ. Hủy thao tác.`);
    return;
  }

  const tempRoot = ensureCleanTempDir(cwd);

  let stagingRoot = null;
  if (isZipFile(inputPath)) {
    console.log(`${LOG} Phát hiện ZIP input: ${inputPath}`);
    stagingRoot = extractZipToTemp(inputPath, tempRoot);
  } else {
    console.log(`${LOG} Input không phải ZIP, copy trực tiếp vào staging.`);
    stagingRoot = stageSingleFile(inputPath, tempRoot);
  }

  const report = await processStagedFiles(stagingRoot, cwd);
  printReport(report, tempRoot);
}

module.exports = { run };
