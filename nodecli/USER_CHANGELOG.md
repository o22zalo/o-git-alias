# USER_CHANGELOG — nodecli / ocli

## 2026-04-05 — Hoàn thiện ocli cloudflared: accountid API, env vars, DNS records

**Loại:** Feature + Refactor

### Những gì đã làm

**`lib/cloudflaredApi.js`:**
- Thêm `loadDotenv()` — parse file `.env` thuần Node (không cần package ngoài), hỗ trợ expand `${VAR}`, bỏ dấu nháy
- Thêm `loadCloudflaredEnv()` — tìm và load `.env` theo thứ tự cwd → nodecli/ → repo root, trả về tất cả biến `CLOUDFLARED_*`
- Thêm `listCloudflareAccounts()` — gọi `/accounts` API để lấy danh sách accounts có quyền truy cập
- Sửa regex parse config: `(\w+)\s*=\s*(.*)$` (cho phép value rỗng, không bắt lỗi với accountid trống)

**`services/cloudflared/index.js`** (viết lại):
- Thêm `resolveAccountId()` — resolve accountid theo thứ tự: config file → env `CLOUDFLARED_ACCOUNT_ID` → gọi API chọn từ danh sách → nhập tay
- Sau khi chọn qua API, hỏi có muốn lưu vào `.cloudflared-o-config` không (tự patch file)
- Thêm `printEnvSummary()` — hiển thị các biến `CLOUDFLARED_*` phát hiện được, nhóm theo Tunnel / Ingress / Khác, ẩn giá trị SECRET/KEY
- Truyền `envVars` xuống `tunnels.run(account, envVars)`

**`services/cloudflared/tunnels.js`** (viết lại):
- Đổi tên tất cả biến env: `TUNNEL_HOSTNAME_N` → `CLOUDFLARED_TUNNEL_HOSTNAME_N`, `TUNNEL_SERVICE_N` → `CLOUDFLARED_TUNNEL_SERVICE_N`
- Thêm `readIngressFromEnv(envVars)` — đọc ingress rules từ `CLOUDFLARED_TUNNEL_HOSTNAME_N` + `SERVICE_N` trong envVars
- `createTunnel()` — đọc `CLOUDFLARED_TUNNEL_NAME` + `CLOUDFLARED_TUNNEL_SECRET` từ env, show và confirm trước khi dùng
- `workflowExistingTunnel()` — tự detect tunnel qua `CLOUDFLARED_TUNNEL_ID` hoặc `CLOUDFLARED_TUNNEL_NAME`, hỏi confirm
- `workflowOutputFiles()` — ưu tiên dùng ingress rules từ `readIngressFromEnv()`, fallback file .env hoặc nhập tay
- Thêm `parseEnvForIngress()` — parse file .env với prefix mới `CLOUDFLARED_TUNNEL_HOSTNAME_N`
- **Thêm mới DNS management:**
  - `getZoneId()` — trích root domain, gọi `/zones?name=` để lấy zone ID
  - `findDnsRecord()` — tìm CNAME record hiện có cho hostname trong zone
  - `createDnsRecord()` — tạo CNAME proxied trỏ về `<tunnelId>.cfargotunnel.com`
  - `updateDnsRecord()` — PATCH record hiện có nếu sai target hoặc không proxied
  - `upsertDnsRecord()` — logic upsert: tìm → cập nhật nếu sai, tạo mới nếu chưa có, bỏ qua nếu đúng rồi
  - `workflowManageDns()` — wizard chọn tunnel → đọc hostnames từ env hoặc nhập tay → upsert CNAME → in tổng kết + gợi ý xử lý lỗi
- `workflowCreateWithOutput()` — sau khi xuất file, hỏi có muốn tạo DNS records ngay không
- Menu tunnels thêm option: `"Tạo / cập nhật DNS records (CNAME) cho tunnel"`

**`nodecli/.cloudflared-o-config.example`:**
- Thêm ghi chú `accountid` là tùy chọn
- Thêm ví dụ account không có accountid
- Thêm mục "BIẾN MÔI TRƯỜNG HỖ TRỢ" với format .env đầy đủ

**Docs:**
- `bin/ocli.js` — cập nhật help text cloudflared
- `nodecli/package.json` — bump version `1.3.0` → `1.4.0`
- `nodecli/README.md` — thêm mục cloudflared đầy đủ: env vars, DNS, flow, Docker deploy
- `nodecli/ProjectStructure.md` — thêm bảng biến CLOUDFLARED_*, cập nhật sơ đồ, danh sách file ZIP

---

## 2026-04-04 — Fix createPipeline + azure/index: UX, API correctness, ProjectStructure

**Loại:** Bugfix + UX improvement

### Những gì đã sửa

**`services/azure/createPipeline.js`:**
- Hardcode `type: 'TfsGit'` thay vì dùng `selectedRepo.type`
- Đổi `recursionLevel=Full` → `recursionLevel=full`
- Guard `defaultBranch`: fallback `refs/heads/main` nếu rỗng
- Thêm auto-prefix `/` khi user nhập path YAML thiếu dấu `/` đầu
- Thêm thông báo rõ ràng khi repo không có file YAML

**`services/azure/index.js`:**
- Bọc bước chọn flow pipeline trong `while (true)`
- Lỗi lấy danh sách pipeline → `continue` quay lại menu

**`ProjectStructure.md`:**
- Thêm `nodecli/services/addfiles/index.js` vào sơ đồ, bảng phụ thuộc, danh sách file ZIP

**`package.json`:**
- Bump version `1.0.0` → `1.3.0`

---

## 2026-04-03 — Thêm tính năng tạo Azure Pipeline từ YAML trong repo

**Yêu cầu:** Trong `ocli azure`, thêm nghiệp vụ tạo pipeline mới, source YAML được chọn trực tiếp từ repository.

**Thay đổi:**
- Tạo mới `nodecli/services/azure/createPipeline.js`
- Cập nhật `nodecli/services/azure/index.js`
- Cập nhật `nodecli/README.md`

---

## 2026-04-03 — Thêm subcommand ocli clip — clipboard → file

**Yêu cầu:** Thêm nghiệp vụ đầu tiên cho `ocli clip`.

**Thay đổi:**
- Tạo mới `nodecli/services/clip/index.js`
- Cập nhật `nodecli/bin/ocli.js`
- Cập nhật `nodecli/README.md`
- Cập nhật `nodecli/ProjectStructure.md`

---

## 2026-04-02 — Thêm subcommand ocli azure — Azure Pipeline Variables

**Thay đổi:**
- Tạo mới `nodecli/lib/azureApi.js`
- Tạo mới `nodecli/services/azure/index.js`
- Tạo mới `nodecli/services/azure/variables.js`
- Tạo mới templates azure-pipeline-vars.*
- Cập nhật `nodecli/bin/ocli.js`, `README.md`, `ProjectStructure.md`, `DeveloperGuide.vi.md`

---

## 2026-04-02 — Khởi tạo nodecli với subcommand ocli gh

**Thay đổi:**
- Tạo mới toàn bộ cấu trúc nodecli/
- Tạo mới subcommand `gh` với secrets management