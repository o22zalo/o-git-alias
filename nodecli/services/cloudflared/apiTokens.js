// services/cloudflared/apiTokens.js — Sinh Account API Token (CF_API_TOKEN) cho cloudflared workflows
"use strict";

const fs = require("fs");
const path = require("path");
const { cloudflaredRequest } = require("../../lib/cloudflaredApi");
const { ask, confirm, selectMenu } = require("../../lib/prompt");

const LOG = "[cloudflared:apiTokens]";

const BOOTSTRAP_TOKEN_ENV_KEYS = [
  "CF_API_TOKEN_BOOTSTRAP",
  "CLOUDFLARED_API_TOKEN_BOOTSTRAP",
  "CLOUDFLARED_BOOTSTRAP_API_TOKEN",
];

const PROFILES = [
  {
    key: "tunnel_only",
    label: "Tunnel only — quản lý Cloudflare Tunnel cho account này",
    recommended: false,
    accountPermissionAliases: [
      ["Cloudflare Tunnel Write", "Cloudflare Tunnel Edit", "Cloudflare One Connector: cloudflared Write", "Cloudflare One Connectors Write"],
      ["Cloudflare Tunnel Read", "Cloudflare One Connector: cloudflared Read", "Cloudflare One Connectors Read"],
    ],
    zonePermissionAliases: [],
  },
  {
    key: "tunnel_dns",
    label: "Tunnel + DNS — tạo tunnel và upsert DNS records",
    recommended: false,
    accountPermissionAliases: [
      ["Cloudflare Tunnel Write", "Cloudflare Tunnel Edit", "Cloudflare One Connector: cloudflared Write", "Cloudflare One Connectors Write"],
      ["Cloudflare Tunnel Read", "Cloudflare One Connector: cloudflared Read", "Cloudflare One Connectors Read"],
    ],
    zonePermissionAliases: [["Zone Read"], ["DNS Write", "DNS Edit"], ["DNS Read"]],
  },
  {
    key: "tunnel_dns_notifications",
    label: "Tunnel + DNS + Notifications — phù hợp project hiện tại",
    recommended: true,
    accountPermissionAliases: [
      ["Cloudflare Tunnel Write", "Cloudflare Tunnel Edit", "Cloudflare One Connector: cloudflared Write", "Cloudflare One Connectors Write"],
      ["Cloudflare Tunnel Read", "Cloudflare One Connector: cloudflared Read", "Cloudflare One Connectors Read"],
      ["Notifications Write", "Notifications Edit"],
      ["Notifications Read"],
    ],
    zonePermissionAliases: [["Zone Read"], ["DNS Write", "DNS Edit"], ["DNS Read"]],
  },
];

function normalizePermissionName(name) {
  return String(name || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function extractApiError(res) {
  if (res && Array.isArray(res.errors) && res.errors.length > 0) {
    const joined = res.errors.map((e) => `[${e.code}] ${e.message}`).join("; ");
    const normalized = joined.toLowerCase();
    if (normalized.includes("account api tokens") || normalized.includes("permission") || normalized.includes("not authorized")) {
      return `${joined} | Bootstrap API token cần quyền: Account API Tokens Write`;
    }
    return joined;
  }
  if (res && res.status) return `status ${res.status}`;
  return "Unknown error";
}

function getDefaultBootstrapToken(envVars) {
  for (const key of BOOTSTRAP_TOKEN_ENV_KEYS) {
    if (envVars && envVars[key] && String(envVars[key]).trim()) {
      return String(envVars[key]).trim();
    }
    if (process.env[key] && String(process.env[key]).trim()) {
      return String(process.env[key]).trim();
    }
  }
  return "";
}

function buildDefaultTokenName(account) {
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z");
  const label = String(account.label || "cloudflare")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "") || "cloudflare";
  return `ocli-cloudflared-${label}-${stamp}`;
}

function buildEnvCandidates() {
  const nodeCliDir = path.resolve(__dirname, "..", "..");
  const repoRoot = path.resolve(nodeCliDir, "..");
  return [path.join(process.cwd(), ".env"), path.join(nodeCliDir, ".env"), path.join(repoRoot, ".env")];
}

function maskToken(token) {
  const raw = String(token || "");
  if (raw.length <= 10) return raw;
  return `${raw.slice(0, 6)}...${raw.slice(-4)}`;
}

function printResolvedGroups(groups, title) {
  if (!groups.length) return;
  console.log(`  ${title}:`);
  for (const item of groups) {
    console.log(`    - ${item.name} (${item.id})`);
  }
}

async function listPermissionGroups(account, bootstrapToken) {
  const res = await cloudflaredRequest({
    method: "GET",
    path: `/accounts/${account.accountid}/tokens/permission_groups`,
    account,
    apiToken: bootstrapToken,
  });

  if (!res.ok) {
    console.error(`${LOG} Không lấy được permission groups: ${extractApiError(res)}`);
    return [];
  }

  return Array.isArray(res.result) ? res.result : [];
}

function findPermissionGroupByAliases(permissionGroups, aliases, expectedScope) {
  const normalizedAliases = aliases.map(normalizePermissionName);
  const matched = permissionGroups.find((item) => {
    const sameName = normalizedAliases.includes(normalizePermissionName(item.name));
    if (!sameName) return false;
    const scopes = Array.isArray(item.scopes) ? item.scopes : [];
    return scopes.includes(expectedScope);
  });

  return matched || null;
}

function resolvePermissionProfile(permissionGroups, profile) {
  const accountGroups = [];
  const zoneGroups = [];
  const missing = [];

  for (const aliases of profile.accountPermissionAliases) {
    const found = findPermissionGroupByAliases(permissionGroups, aliases, "com.cloudflare.api.account");
    if (!found) {
      missing.push(aliases[0]);
      continue;
    }
    accountGroups.push({ id: found.id, name: found.name });
  }

  for (const aliases of profile.zonePermissionAliases) {
    const found = findPermissionGroupByAliases(permissionGroups, aliases, "com.cloudflare.api.account.zone");
    if (!found) {
      missing.push(aliases[0]);
      continue;
    }
    zoneGroups.push({ id: found.id, name: found.name });
  }

  return { accountGroups, zoneGroups, missing };
}

function buildPolicies(accountId, resolvedProfile) {
  const policies = [];

  if (resolvedProfile.accountGroups.length > 0) {
    policies.push({
      effect: "allow",
      resources: {
        [`com.cloudflare.api.account.${accountId}`]: "*",
      },
      permission_groups: resolvedProfile.accountGroups,
    });
  }

  if (resolvedProfile.zoneGroups.length > 0) {
    policies.push({
      effect: "allow",
      resources: {
        [`com.cloudflare.api.account.${accountId}`]: {
          "com.cloudflare.api.account.zone.*": "*",
        },
      },
      permission_groups: resolvedProfile.zoneGroups,
    });
  }

  return policies;
}

async function createAccountApiToken(account, bootstrapToken, payload) {
  const res = await cloudflaredRequest({
    method: "POST",
    path: `/accounts/${account.accountid}/tokens`,
    body: payload,
    account,
    apiToken: bootstrapToken,
  });

  if (!res.ok) {
    console.error(`${LOG} Tạo CF_API_TOKEN thất bại: ${extractApiError(res)}`);
    return null;
  }

  return res.result || null;
}

function upsertEnvVar(filePath, key, value) {
  const target = path.resolve(filePath);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  const exists = fs.existsSync(target);
  const lines = exists ? fs.readFileSync(target, "utf8").split(/\r?\n/) : [];
  let replaced = false;
  const out = [];

  for (const line of lines) {
    if (line.trim().startsWith(`${key}=`)) {
      out.push(`${key}=${value}`);
      replaced = true;
      continue;
    }
    out.push(line);
  }

  if (!replaced) {
    if (out.length > 0 && out[out.length - 1] !== "") out.push("");
    out.push(`${key}=${value}`);
  }

  fs.writeFileSync(target, out.join("\n"), "utf8");
  return target;
}

function buildExpiryIso(daysRaw) {
  const days = parseInt(String(daysRaw || "").trim(), 10);
  if (!Number.isFinite(days) || days <= 0) return "";
  const expires = new Date(Date.now() + days * 24 * 60 * 60 * 1000);
  return expires.toISOString().replace(/\.\d{3}Z$/, "Z");
}

async function selectProfile() {
  const idx = await selectMenu(
    "Profile quyền cho CF_API_TOKEN",
    PROFILES.map((item) => ({
      label: `${item.label}${item.recommended ? "  [khuyên dùng]" : ""}`,
    })),
  );
  if (idx === -1) return null;
  return PROFILES[idx];
}

async function handleGenerateToken(account, envVars) {
  const defaultBootstrapToken = getDefaultBootstrapToken(envVars);
  console.log(`\n${LOG} Endpoint tạo token của Cloudflare yêu cầu bootstrap API token (Bearer) có quyền Account API Tokens Write.`);

  const bootstrapToken = await ask("  Bootstrap API token (Bearer)", defaultBootstrapToken);
  if (!bootstrapToken || !String(bootstrapToken).trim()) {
    console.log("  Hủy.");
    return;
  }

  const profile = await selectProfile();
  if (!profile) return;

  const name = await ask("  Tên token", buildDefaultTokenName(account));
  if (!name || !String(name).trim()) {
    console.log("  Hủy.");
    return;
  }

  const expiresDays = await ask("  Số ngày hết hạn (Enter = 365 ngày, 0 = không hết hạn)", "365");
  const expiresOn = buildExpiryIso(expiresDays);

  console.log(`\n${LOG} Đang lấy permission groups cho account ${account.accountid}...`);
  const permissionGroups = await listPermissionGroups(account, bootstrapToken);
  if (permissionGroups.length === 0) return;

  const resolvedProfile = resolvePermissionProfile(permissionGroups, profile);
  if (resolvedProfile.missing.length > 0) {
    console.error(`${LOG} Không map được các permission groups sau: ${resolvedProfile.missing.join(", ")}`);
    console.error(`${LOG} Cloudflare có thể đang đổi tên quyền hoặc account này chưa hỗ trợ profile đã chọn.`);
    return;
  }

  console.log("");
  console.log(`  account     : ${account.label} (${account.accountid})`);
  console.log(`  token name  : ${name}`);
  console.log(`  profile     : ${profile.label}`);
  console.log(`  expires_on  : ${expiresOn || "(không hết hạn)"}`);
  console.log(`  bootstrap   : ${maskToken(bootstrapToken)}`);
  printResolvedGroups(resolvedProfile.accountGroups, "Account permissions");
  printResolvedGroups(resolvedProfile.zoneGroups, "Zone permissions");
  console.log("");

  const ok = await confirm("  Xác nhận tạo CF_API_TOKEN?", true);
  if (!ok) {
    console.log("  Hủy.");
    return;
  }

  const payload = {
    name,
    policies: buildPolicies(account.accountid, resolvedProfile),
  };
  if (expiresOn) payload.expires_on = expiresOn;

  const created = await createAccountApiToken(account, bootstrapToken, payload);
  if (!created || !created.value) {
    console.error(`${LOG} API không trả về token value. Không thể tiếp tục.`);
    return;
  }

  console.log(`\n${LOG} ✓ Đã tạo CF_API_TOKEN: ${created.name || name}`);
  console.log(`  token_id    : ${created.id || "unknown"}`);
  console.log(`  status      : ${created.status || "active"}`);
  console.log(`  CF_API_TOKEN=${created.value}`);
  console.log("");

  const saveToEnv = await confirm("  Ghi CF_API_TOKEN vào file .env?", true);
  if (!saveToEnv) return;

  const candidates = buildEnvCandidates();
  const defaultEnvPath = candidates.find((item) => fs.existsSync(item)) || candidates[0];
  const envPath = await ask("  Đường dẫn file .env để ghi", defaultEnvPath);
  if (!envPath || !String(envPath).trim()) {
    console.log("  Bỏ qua ghi file.");
    return;
  }

  try {
    const savedPath = upsertEnvVar(envPath, "CF_API_TOKEN", created.value);
    console.log(`${LOG} ✓ Đã ghi CF_API_TOKEN vào: ${savedPath}`);
  } catch (e) {
    console.error(`${LOG} Không ghi được file .env: ${e.message}`);
  }
}

async function run(account, envVars) {
  while (true) {
    const idx = await selectMenu(`CF_API_TOKEN — ${account.label} (${account.accountid})`, [
      { label: "Sinh Account API Token cho cloudflared workflows" },
    ]);

    if (idx === -1) break;
    if (idx === 0) await handleGenerateToken(account, envVars || {});
  }
}

module.exports = { run };
