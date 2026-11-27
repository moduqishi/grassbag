/**
 * Standalone responsive HTML Pairing & QR Code Dashboard served at `/gbridge/ui`
 * on DSH's existing `ctx.webServer` (and optionally on the Desktop LAN bridge).
 * Zero external assets or CDN requests — renders crisp inline SVG QR codes immediately.
 */

function escapeHtml(raw) {
  return String(raw ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

export function renderPairingDashboardHtml(snapshot, { apiPath = '/api/gbridge/pairing' } = {}) {
  const safeJson = JSON.stringify(snapshot).replace(/</g, '\\u003c').replace(/>/g, '\\u003e');
  const title = `GrassBag 手机配对 · ${escapeHtml(snapshot.hostName || 'DSH')}`;
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title>
<style>
  :root {
    --bg: #f4f7f6;
    --card: rgba(255,255,255,0.88);
    --stroke: rgba(15,23,42,0.09);
    --text: #0f172a;
    --text2: #475569;
    --text3: #64748b;
    --accent: #0f766e;
    --accent-fg: #ffffff;
    --accent-soft: rgba(15,118,110,0.11);
    --ok: #15803d;
    --ok-soft: rgba(21,128,61,0.12);
    --warn: #b45309;
    --warn-soft: rgba(180,83,9,0.12);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0b1115;
      --card: rgba(19,27,33,0.88);
      --stroke: rgba(255,255,255,0.10);
      --text: #f1f5f9;
      --text2: #cbd5e1;
      --text3: #94a3b8;
      --accent: #2dd4bf;
      --accent-fg: #042f2e;
      --accent-soft: rgba(45,212,191,0.14);
      --ok: #4ade80;
      --ok-soft: rgba(74,222,128,0.14);
      --warn: #fbbf24;
      --warn-soft: rgba(251,191,36,0.14);
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100vh;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, sans-serif;
    background: radial-gradient(circle at top right, rgba(45,212,191,0.14), transparent 45%), var(--bg);
    color: var(--text);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 24px;
  }
  .shell {
    width: 100%;
    max-width: 720px;
    background: var(--card);
    border: 1px solid var(--stroke);
    border-radius: 24px;
    padding: 26px;
    backdrop-filter: blur(18px);
    box-shadow: 0 20px 50px rgba(0,0,0,0.08);
  }
  .head { display: flex; align-items: center; justify-content: space-between; gap: 14px; flex-wrap: wrap; }
  .brand { display: flex; align-items: center; gap: 12px; }
  .logo {
    width: 42px; height: 42px; border-radius: 13px;
    background: linear-gradient(135deg, #34d399, #0f766e);
    display: flex; align-items: center; justify-content: center; flex-shrink: 0;
  }
  h1 { margin: 0; font-size: 19px; font-weight: 700; letter-spacing: -0.02em; }
  .sub { margin: 3px 0 0; font-size: 12.5px; color: var(--text3); }
  .pill {
    display: inline-flex; align-items: center; gap: 6px;
    padding: 6px 11px; border-radius: 999px; font-size: 12px; font-weight: 600;
    background: var(--ok-soft); color: var(--ok);
  }
  .pill.warn { background: var(--warn-soft); color: var(--warn); }
  .dot { width: 7px; height: 7px; border-radius: 50%; background: currentColor; }
  .grid { display: grid; grid-template-columns: 244px 1fr; gap: 22px; margin-top: 22px; align-items: start; }
  @media (max-width: 640px) { .grid { grid-template-columns: 1fr; } }
  .qr-card {
    background: #fff; border-radius: 20px; padding: 14px;
    border: 1px solid rgba(15,23,42,0.08);
    display: flex; flex-direction: column; align-items: center; gap: 10px;
  }
  .qr-card svg { width: 216px; height: 216px; display: block; border-radius: 10px; }
  .qr-cap { font-size: 11.5px; color: #475569; text-align: center; font-weight: 500; }
  .chips { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 12px; }
  .chip {
    border: 1px solid var(--stroke); background: transparent; color: var(--text2);
    border-radius: 10px; padding: 6px 10px; font-size: 12px; font-weight: 600; cursor: pointer;
  }
  .chip.active { background: var(--accent-soft); border-color: var(--accent); color: var(--accent); }
  .box {
    border: 1px solid var(--stroke); border-radius: 14px; padding: 12px 13px;
    margin-bottom: 12px; background: rgba(127,127,127,0.04);
  }
  .label { font-size: 11px; font-weight: 600; color: var(--text3); margin-bottom: 5px; }
  .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; word-break: break-all; color: var(--text); }
  .actions { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 10px; }
  .btn {
    border: 1px solid var(--stroke); background: transparent; color: var(--text);
    border-radius: 11px; padding: 8px 13px; font-size: 12.5px; font-weight: 600; cursor: pointer;
  }
  .btn.primary { background: var(--accent); border-color: var(--accent); color: var(--accent-fg); }
  .btn:disabled { opacity: 0.5; cursor: default; }
  .toast { margin-top: 10px; font-size: 12px; color: var(--accent); min-height: 18px; }
  .meta { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 14px; padding-top: 14px; border-top: 1px solid var(--stroke); font-size: 12px; color: var(--text3); }
</style>
</head>
<body>
  <main class="shell">
    <div class="head">
      <div class="brand">
        <div class="logo">
          <svg width="24" height="24" viewBox="0 0 64 64" fill="none">
            <path d="M18 44c0-13 10-24 27-25-1.2 16-10 26-24 26h-3v-1Z" fill="#ecfdf5"/>
            <path d="M19 45c8-6.5 16-13 23-19" stroke="#0f766e" stroke-width="4" stroke-linecap="round"/>
          </svg>
        </div>
        <div>
          <h1>GrassBag 手机扫码配对</h1>
          <p class="sub" id="subtitle">加载中…</p>
        </div>
      </div>
      <span class="pill" id="mode-pill"><span class="dot"></span><span id="mode-text">就绪</span></span>
    </div>

    <div class="grid">
      <div class="qr-card">
        <div id="qr-slot"></div>
        <div class="qr-cap">打开手机 GrassBag → 扫码连接</div>
      </div>
      <div>
        <div class="label">选择本机网络地址</div>
        <div class="chips" id="ip-chips"></div>

        <div class="box">
          <div class="label">配对链接（扫码或粘贴至 GrassBag）</div>
          <div class="mono" id="pair-url">--</div>
        </div>

        <div class="actions">
          <button class="btn primary" id="copy-url-btn">复制配对链接</button>
          <button class="btn" id="copy-token-btn">复制令牌</button>
          <button class="btn" id="rotate-btn">重置令牌</button>
          <button class="btn" id="toggle-lan-btn" style="display:none">开启局域网桥接</button>
          <button class="btn" id="refresh-btn">刷新状态</button>
        </div>
        <div class="toast" id="toast"></div>
      </div>
    </div>

    <div class="meta" id="meta-bar"></div>
  </main>
<script>
const API_PATH = ${JSON.stringify(apiPath)};
let state = ${safeJson};
let selectedIdx = 0;
let busy = false;

function showToast(msg) {
  const el = document.getElementById('toast');
  el.textContent = msg;
  clearTimeout(showToast._t);
  showToast._t = setTimeout(() => { el.textContent = ''; }, 2800);
}

async function copyTextSafe(text) {
  if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch (_clipboardErr) {
      // Non-HTTPS LAN origin may block navigator.clipboard; fall through to execCommand('copy').
    }
  }
  try {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', 'true');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    ta.style.top = '-9999px';
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    const ok = document.execCommand('copy');
    document.body.removeChild(ta);
    return Boolean(ok);
  } catch {
    return false;
  }
}

function setBusyState(nextBusy) {
  busy = nextBusy;
  for (const id of ['rotate-btn', 'toggle-lan-btn', 'refresh-btn']) {
    const btn = document.getElementById(id);
    if (btn) btn.disabled = nextBusy;
  }
}

function renderQrSvg(qr) {
  if (!qr || !qr.pathData) return '<div style="width:216px;height:216px;display:flex;align-items:center;justify-content:center;color:#64748b;font-size:12px;">暂无可用局域网地址</div>';
  return '<svg xmlns="http://www.w3.org/2000/svg" width="216" height="216" viewBox="0 0 ' + qr.viewBoxSize + ' ' + qr.viewBoxSize + '" shape-rendering="crispEdges"><rect width="' + qr.viewBoxSize + '" height="' + qr.viewBoxSize + '" fill="#ffffff"/><path d="' + qr.pathData + '" fill="#0f172a"/></svg>';
}

function render() {
  const eps = Array.isArray(state.endpoints) ? state.endpoints : [];
  if (selectedIdx >= eps.length) selectedIdx = 0;
  const active = eps[selectedIdx] || null;

  document.getElementById('subtitle').textContent = (state.hostName || 'DSH') + ' · dsh-gbridge v' + (state.bridgeVersion || '0.2.0') + ' · DSH ' + (state.dshVersion || '');
  const pill = document.getElementById('mode-pill');
  const modeText = document.getElementById('mode-text');
  if (state.mode === 'shared-webserver') {
    pill.className = 'pill';
    modeText.textContent = '复用 DSH Web 端口 :' + (state.activePort || '--') + ' · 零额外端口';
  } else if (state.mode === 'lan-bridge' && state.lan && state.lan.listening) {
    pill.className = 'pill';
    modeText.textContent = '内置局域网桥接 :' + state.lan.port + (state.portConflictAvoided ? '（已自动避让冲突端口）' : ' · 零冲突');
  } else {
    pill.className = 'pill warn';
    modeText.textContent = '仅本机回环（未开放局域网）';
  }

  document.getElementById('qr-slot').innerHTML = renderQrSvg(active && active.qr);
  document.getElementById('pair-url').textContent = active ? active.url : '请开启局域网桥接或使用 --host <局域网IP> 启动 dsh web';

  const chips = document.getElementById('ip-chips');
  chips.innerHTML = '';
  eps.forEach((ep, idx) => {
    const b = document.createElement('button');
    b.className = 'chip' + (idx === selectedIdx ? ' active' : '');
    b.textContent = (ep.label || ep.iface) + ' · ' + ep.ip;
    b.onclick = () => { selectedIdx = idx; render(); };
    chips.appendChild(b);
  });

  const toggleBtn = document.getElementById('toggle-lan-btn');
  if (state.mode !== 'shared-webserver') {
    toggleBtn.style.display = 'inline-block';
    toggleBtn.textContent = (state.lan && state.lan.enabled) ? '暂停局域网桥接' : '开启局域网桥接';
  } else {
    toggleBtn.style.display = 'none';
  }

  const canRotate = state.canRotateToken !== undefined ? Boolean(state.canRotateToken) : state.mode === 'lan-bridge';
  document.getElementById('rotate-btn').style.display = canRotate ? 'inline-block' : 'none';
  document.getElementById('copy-token-btn').style.display = state.token ? 'inline-block' : 'none';

  document.getElementById('meta-bar').innerHTML =
    '<span>已连接手机客户端：<strong>' + (state.connectedClients || 0) + '</strong></span>' +
    '<span>模式：<strong>' + (state.surface || 'web') + '</strong></span>' +
    '<span>协议：<strong>/gbridge/v1</strong></span>';
}

async function parseSafeJson(res) {
  const text = await res.text();
  if (!text) return null;
  try { return JSON.parse(text); } catch { return null; }
}

async function refreshState(silent = false) {
  if (busy) return;
  if (!silent) setBusyState(true);
  try {
    const res = await fetch(API_PATH, {
      method: 'GET',
      credentials: 'same-origin',
      cache: 'no-store',
    });
    const data = await parseSafeJson(res);
    if (!res.ok) throw new Error((data && data.error && data.error.message) || ('HTTP ' + res.status));
    if (data && typeof data === 'object') {
      state = data;
      render();
    }
  } catch (e) {
    if (!silent) showToast('刷新失败：' + (e && e.message ? e.message : String(e)));
  } finally {
    if (!silent) setBusyState(false);
  }
}

async function callAction(payload) {
  if (busy) return;
  setBusyState(true);
  try {
    const res = await fetch(API_PATH, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify(payload),
    });
    const data = await parseSafeJson(res);
    if (!res.ok) throw new Error((data && data.error && data.error.message) || ('HTTP ' + res.status));
    if (data && typeof data === 'object') {
      state = data;
      render();
    }
  } finally {
    setBusyState(false);
  }
}

document.getElementById('copy-url-btn').onclick = async () => {
  const eps = state.endpoints || [];
  const active = eps[selectedIdx];
  if (!active) return showToast('暂无可复制的配对链接');
  const ok = await copyTextSafe(active.url);
  showToast(ok ? '已复制配对链接' : '复制失败，请手动选中复制');
};
document.getElementById('copy-token-btn').onclick = async () => {
  if (!state.token) return showToast('当前复用 DSH 登录态，无需单独令牌');
  const ok = await copyTextSafe(state.token);
  showToast(ok ? '已复制连接令牌' : '复制失败，请手动选中复制');
};
document.getElementById('rotate-btn').onclick = async () => {
  try { await callAction({ action: 'rotateToken' }); showToast('已重置令牌，旧设备需重新扫码授权'); } catch (e) { showToast('重置失败：' + e.message); }
};
document.getElementById('toggle-lan-btn').onclick = async () => {
  try {
    const next = !(state.lan && state.lan.enabled);
    await callAction({ action: 'setLanEnabled', enabled: next });
    showToast(next ? '已开启零冲突局域网桥接' : '已暂停局域网桥接（如需恢复请从电脑端面板重新开启）');
  } catch (e) {
    showToast('操作失败：' + e.message);
  }
};
document.getElementById('refresh-btn').onclick = async () => {
  await refreshState(false);
};

setInterval(() => {
  if (!document.hidden && !busy) {
    void refreshState(true);
  }
}, 10000);

render();
</script>
</body>
</html>`;
}
