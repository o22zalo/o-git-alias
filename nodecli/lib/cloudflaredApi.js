// lib/cloudflaredApi.js — Gọi Cloudflare REST API qua https built-in
// Auth: X-Auth-Email + X-Auth-Key từ .cloudflared-o-config
// Không dùng axios hay node-fetch — chỉ dùng https của Node.

"use strict";

const https = require("https");
const fs = require("fs");
const path = require("path");
const os = require("os");

const LOG = "[cloudflaredApi]";

// ─────────────────────────────────────────────────────────────────
// Load .env file vào process.env (dotenv-style, không cần package ngoài)
// Hỗ trợ: KEY=value, KEY="value", KEY='value', comment #, expand ${VAR}
// ─────────────────────────────────────────────────────────────────

function loadDotenv(envFilePath) {
  if (!fs.existsSync(envFilePath)) return {};

  const raw = fs.readFileSync(envFilePath, "utf8");
  const loaded = {};

  for (const rawLine of raw.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;

    const eq = line.indexOf("=");
    if (eq === -1) continue;

    const key = line.slice(0, eq).trim();
    let val = line.slice(eq + 1).trim();

    // Bỏ dấu nháy bao quanh
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    }

    // Expand ${VAR} hoặc $VAR đơn giản
    val = val.replace(/\$\{([^}]+)\}/g, (_, k) => process.env[k] || loaded[k] || "");
    val = val.replace(/\$([A-Z_][A-Z0-9_]*)/g, (_, k) => process.env[k] || loaded[k] || "");

    loaded[key] = val;
    if (!(key in process.env)) process.env[key] = val;
  }

  return loaded;
}

/**
 * Load .env file và trả về các biến CLOUDFLARED_* đang có trong process.env.
 * Tìm .env theo thứ tự: cwd → thư mục nodecli → thư mục gốc repo.
 */
function loadCloudflaredEnv(envFilePath) {
  const candidates = [];

  if (envFilePath) {
    candidates.push(envFilePath);
  } else {
    candidates.push(path.join(process.cwd(), ".env"), path.resolve(__dirname, "..", ".env"), path.resolve(__dirname, "..", "..", ".env"));
  }

  let loaded = {};
  for (const p of candidates) {
    if (fs.existsSync(p)) {
      loaded = loadDotenv(p);
      break;
    }
  }

  // Trả về tất cả key CLOUDFLARED_* từ process.env (bao gồm cả load mới + có sẵn)
  const result = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (k.startsWith("CLOUDFLARED_")) result[k] = v;
  }

  return { vars: result, loaded };
}

// ─────────────────────────────────────────────────────────────────
// Parse .cloudflared-o-config (INI-style)
// Format:
//   [label]
//   email=...
//   apikey=...
//   accountid=...    ← tùy chọn, có thể bỏ trống để chọn qua API
// ─────────────────────────────────────────────────────────────────

function resolveCloudflaredConfigPath() {
  const nodeCliDir = path.resolve(__dirname, "..");
  const candidate = path.join(nodeCliDir, ".cloudflared-o-config");
  if (fs.existsSync(candidate)) return candidate;

  const homeCand = path.join(os.homedir(), ".cloudflared-o-config");
  if (fs.existsSync(homeCand)) return homeCand;

  return null;
}

function parseCloudflaredConfig(filePath) {
  const raw = fs.readFileSync(filePath, "utf8");
  const lines = raw.split(/\r?\n/);

  const sections = [];
  let cur = null;

  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;

    const secMatch = line.match(/^\[(.+)\]$/);
    if (secMatch) {
      cur = { label: secMatch[1], email: "", apikey: "", accountid: "" };
      sections.push(cur);
      continue;
    }

    if (!cur) continue;

    const kv = line.match(/^(\w+)\s*=\s*(.*)$/);
    if (!kv) continue;

    const [, key, val] = kv;
    if (key === "email") cur.email = val.trim();
    if (key === "apikey") cur.apikey = val.trim();
    if (key === "accountid") cur.accountid = val.trim();
  }

  return sections;
}

/**
 * Load tất cả sections từ .cloudflared-o-config
 * Throw nếu không tìm thấy file.
 */
function loadCloudflaredSections() {
  const cfgPath = resolveCloudflaredConfigPath();
  if (!cfgPath) {
    throw new Error(
      `${LOG} Không tìm thấy .cloudflared-o-config.\n` +
        "  Tạo từ mẫu: cp nodecli/.cloudflared-o-config.example nodecli/.cloudflared-o-config\n" +
        "  Điền email, apikey, accountid của bạn.",
    );
  }
  return { sections: parseCloudflaredConfig(cfgPath), filePath: cfgPath };
}

// ─────────────────────────────────────────────────────────────────
// Build auth headers từ account object
// ─────────────────────────────────────────────────────────────────

function buildHeaders(account, extraHeaders = {}, apiToken = "") {
  const trimmedToken = String(apiToken || "").trim();
  if (trimmedToken) {
    return {
      Authorization: `Bearer ${trimmedToken}`,
      "Content-Type": "application/json",
      Accept: "application/json",
      ...extraHeaders,
    };
  }

  if (!account || !account.email || !account.apikey) {
    throw new Error(`${LOG} Thiếu email hoặc apikey cho account${account && account.label ? `: ${account.label}` : ""}`);
  }
  return {
    "X-Auth-Email": account.email,
    "X-Auth-Key": account.apikey,
    "Content-Type": "application/json",
    Accept: "application/json",
    ...extraHeaders,
  };
}

// ─────────────────────────────────────────────────────────────────
// HTTP helper
// ─────────────────────────────────────────────────────────────────

/**
 * Gọi Cloudflare REST API.
 *
 * @param {object} opts
 *   method    : 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'
 *   path      : path sau https://api.cloudflare.com/client/v4
 *   body      : object (JSON) hoặc undefined
 *   account   : { label, email, apikey, accountid }
 *
 * @returns Promise<{ ok, status, result, errors, messages, raw }>
 */
function cloudflaredRequest(opts) {
  const { method = "GET", path: apiPath, body, account, apiToken = "" } = opts;

  let headers;
  try {
    headers = buildHeaders(account, {}, apiToken);
  } catch (e) {
    return Promise.reject(e);
  }

  const bodyStr = body ? JSON.stringify(body) : "";
  if (bodyStr) {
    headers["Content-Length"] = Buffer.byteLength(bodyStr);
  }

  const hostname = "api.cloudflare.com";
  const fullPath = `/client/v4${apiPath}`;

  return new Promise((resolve, reject) => {
    const req = https.request({ hostname, path: fullPath, method, headers }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const raw = Buffer.concat(chunks).toString("utf8");
        let parsed = null;
        try {
          parsed = JSON.parse(raw);
        } catch {
          parsed = { success: false, _rawText: raw };
        }

        const ok = res.statusCode >= 200 && res.statusCode < 300 && parsed.success !== false;
        resolve({
          ok,
          status: res.statusCode,
          result: parsed.result ?? null,
          errors: parsed.errors ?? [],
          messages: parsed.messages ?? [],
          raw,
        });
      });
    });

    req.on("error", reject);
    if (bodyStr) req.write(bodyStr);
    req.end();
  });
}

// ─────────────────────────────────────────────────────────────────
// API: Lấy danh sách accounts mà API key có quyền truy cập
// ─────────────────────────────────────────────────────────────────

/**
 * Lấy danh sách accounts từ Cloudflare API.
 * @returns Promise<Array<{ id, name, type }>>
 */
async function listCloudflareAccounts(account) {
  const res = await cloudflaredRequest({
    method: "GET",
    path: "/accounts?per_page=50",
    account,
  });

  if (!res.ok) {
    const errMsg = (res.errors || []).map((e) => e.message).join("; ") || `status ${res.status}`;
    throw new Error(`${LOG} Không lấy được danh sách accounts: ${errMsg}`);
  }

  return (res.result || []).map((a) => ({
    id: a.id,
    name: a.name,
    type: a.type || "standard",
  }));
}

module.exports = {
  cloudflaredRequest,
  loadCloudflaredSections,
  resolveCloudflaredConfigPath,
  loadCloudflaredEnv,
  listCloudflareAccounts,
  loadDotenv,
};
