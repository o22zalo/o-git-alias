// services/cloudflared/index.js — Subcommand `ocli cloudflared`
// Flow: load .env → chọn account từ .cloudflared-o-config
//       → resolve accountid (config / API / env) → chọn nhóm chức năng

"use strict";

const { loadCloudflaredSections, listCloudflareAccounts, loadCloudflaredEnv } = require("../../lib/cloudflaredApi");
const { selectMenu, ask, confirm } = require("../../lib/prompt");
const tunnels = require("./tunnels");
const apiTokens = require("./apiTokens");

const LOG = "[cloudflared]";

// ─────────────────────────────────────────────────────────────────
// Resolve accountid: config → env → API
// ─────────────────────────────────────────────────────────────────

async function resolveAccountId(account, envVars) {
  // Ưu tiên 1: accountid đã có trong config
  if (account.accountid && account.accountid.trim()) {
    console.log(`${LOG} Account ID: ${account.accountid} (từ cấu hình)`);
    return account.accountid.trim();
  }

  // Ưu tiên 2: CLOUDFLARED_ACCOUNT_ID trong env
  const envAccountId = envVars["CLOUDFLARED_ACCOUNT_ID"];
  if (envAccountId && envAccountId.trim()) {
    console.log(`${LOG} Account ID: ${envAccountId} (từ env CLOUDFLARED_ACCOUNT_ID)`);
    return envAccountId.trim();
  }

  // Ưu tiên 3: Lấy từ API để chọn
  console.log(`\n${LOG} Chưa có accountid — đang lấy danh sách accounts từ Cloudflare API...`);

  let cfAccounts = [];
  try {
    cfAccounts = await listCloudflareAccounts(account);
  } catch (e) {
    console.error(`${LOG} ${e.message}`);
  }

  if (cfAccounts.length === 0) {
    console.log(`${LOG} Không lấy được accounts qua API. Vui lòng nhập thủ công.`);
    const manual = await ask("  Account ID (Cloudflare Account ID)");
    if (!manual || !manual.trim()) return null;
    return manual.trim();
  }

  if (cfAccounts.length === 1) {
    console.log(`${LOG} Chỉ có 1 account: ${cfAccounts[0].name} (${cfAccounts[0].id})`);
    const ok = await confirm(`  Dùng account này?`, true);
    if (!ok) return null;
    return cfAccounts[0].id;
  }

  // Nhiều accounts → cho chọn
  const idx = await selectMenu(
    "Chọn Cloudflare Account",
    cfAccounts.map((a) => ({
      label: `${a.name.padEnd(40)} ${a.id}  [${a.type}]`,
    })),
  );
  if (idx === -1) return null;

  const chosen = cfAccounts[idx];
  console.log(`${LOG} Đã chọn account: ${chosen.name} (${chosen.id})`);

  // Hỏi có muốn lưu vào config không
  const saveOk = await confirm("  Lưu accountid này vào .cloudflared-o-config?", false);
  if (saveOk) {
    _saveAccountIdToConfig(account.label, chosen.id);
  }

  return chosen.id;
}

// ─────────────────────────────────────────────────────────────────
// Ghi accountid vào .cloudflared-o-config (sau section tương ứng)
// ─────────────────────────────────────────────────────────────────

function _saveAccountIdToConfig(label, accountId) {
  const { resolveCloudflaredConfigPath } = require("../../lib/cloudflaredApi");
  const fs = require("fs");
  const path = require("path");

  const cfgPath = resolveCloudflaredConfigPath();
  if (!cfgPath) {
    console.warn(`${LOG} Không tìm thấy file config để ghi.`);
    return;
  }

  const raw = fs.readFileSync(cfgPath, "utf8");
  const lines = raw.split(/\r?\n/);
  const out = [];
  let inSection = false;
  let wrote = false;

  for (const line of lines) {
    const trimmed = line.trim();
    const secMatch = trimmed.match(/^\[(.+)\]$/);

    if (secMatch) {
      // Nếu đang ở section cần ghi và chưa ghi → ghi trước khi chuyển section
      if (inSection && !wrote) {
        out.push(`accountid=${accountId}`);
        wrote = true;
      }
      inSection = secMatch[1] === label;
    }

    // Bỏ dòng accountid cũ trong section này
    if (inSection && trimmed.startsWith("accountid=")) {
      out.push(`accountid=${accountId}`);
      wrote = true;
      continue;
    }

    out.push(line);
  }

  // Nếu cuối file vẫn trong section mà chưa ghi
  if (inSection && !wrote) {
    out.push(`accountid=${accountId}`);
  }

  fs.writeFileSync(cfgPath, out.join("\n"), "utf8");
  console.log(`${LOG} ✓ Đã lưu accountid vào config: ${cfgPath}`);
}

// ─────────────────────────────────────────────────────────────────
// Hiển thị các biến CLOUDFLARED_* có sẵn trong process.env
// ─────────────────────────────────────────────────────────────────

function printEnvSummary(envVars) {
  const keys = Object.keys(envVars).sort();
  if (keys.length === 0) return;

  console.log(`\n${LOG} Biến CLOUDFLARED_* phát hiện trong môi trường:`);
  console.log("");

  // Nhóm các key liên quan
  const groups = {
    Tunnel: keys.filter((k) =>
      ["CLOUDFLARED_TUNNEL_NAME", "CLOUDFLARED_TUNNEL_ID", "CLOUDFLARED_TUNNEL_SECRET", "CLOUDFLARED_ACCOUNT_ID"].includes(k),
    ),
    Ingress: keys.filter((k) => k.match(/^CLOUDFLARED_TUNNEL_(HOSTNAME|SERVICE)_\d+$/)),
    Khác: keys.filter(
      (k) =>
        !["CLOUDFLARED_TUNNEL_NAME", "CLOUDFLARED_TUNNEL_ID", "CLOUDFLARED_TUNNEL_SECRET", "CLOUDFLARED_ACCOUNT_ID"].includes(k) &&
        !k.match(/^CLOUDFLARED_TUNNEL_(HOSTNAME|SERVICE)_\d+$/),
    ),
  };

  for (const [groupName, groupKeys] of Object.entries(groups)) {
    if (groupKeys.length === 0) continue;
    console.log(`  [${groupName}]`);
    for (const k of groupKeys) {
      const v = envVars[k];
      const display = k.includes("SECRET") || k.includes("KEY") ? `${v.slice(0, 8)}...` : v;
      console.log(`    ${k.padEnd(42)} = ${display}`);
    }
    console.log("");
  }
}

// ─────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────

async function run() {
  // ── Load env vars CLOUDFLARED_* ────────────────────────────────────
  const { vars: envVars } = loadCloudflaredEnv();

  // ── Load + chọn account ────────────────────────────────────────────
  let sections;
  try {
    const cfg = loadCloudflaredSections();
    sections = cfg.sections;
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }

  if (sections.length === 0) {
    console.error(`${LOG} Không tìm thấy account nào trong .cloudflared-o-config.`);
    console.error(`${LOG}   Tạo file:`);
    console.error(`${LOG}   cp nodecli/.cloudflared-o-config.example nodecli/.cloudflared-o-config`);
    process.exit(1);
  }

  // Validate có email + apikey
  const valid = sections.filter((s) => s.email && s.apikey);
  if (valid.length === 0) {
    console.error(`${LOG} Các account trong .cloudflared-o-config đều thiếu email/apikey.`);
    process.exit(1);
  }

  if (valid.length < sections.length) {
    console.warn(`${LOG} Bỏ qua ${sections.length - valid.length} account(s) thiếu thông tin.`);
  }

  const accountIdx = await selectMenu(
    "Chọn Cloudflare account",
    valid.map((s) => ({
      label: `${s.label.padEnd(20)}  ${s.email.padEnd(35)}  ${s.accountid ? `accountid: ${s.accountid}` : "(accountid chưa cấu hình)"}`,
    })),
  );
  if (accountIdx === -1) return;

  const account = { ...valid[accountIdx] };
  console.log(`\n${LOG} Account: ${account.label} (${account.email})`);

  // ── Resolve accountid ──────────────────────────────────────────────
  const accountId = await resolveAccountId(account, envVars);
  if (!accountId) {
    console.error(`${LOG} Không xác định được Account ID. Hủy.`);
    return;
  }
  account.accountid = accountId;

  // ── Hiển thị env vars có sẵn ──────────────────────────────────────
  printEnvSummary(envVars);

  // ── Vòng lặp chọn nhóm chức năng ──────────────────────────────────
  while (true) {
    const groupIdx = await selectMenu(`Cloudflare — ${account.label} (${account.accountid})`, [
      { label: "Tunnels — tạo/quản lý tunnel, DNS records, xuất credentials + config Docker" },
      { label: "CF_API_TOKEN — sinh Account API Token cho cloudflared workflows" },
      // Thêm nhóm chức năng mới ở đây (DNS, Workers, v.v.)
    ]);
    if (groupIdx === -1) break;

    if (groupIdx === 0) {
      await tunnels.run(account, envVars);
    }
    if (groupIdx === 1) {
      await apiTokens.run(account, envVars);
    }
  }
}

module.exports = { run };
