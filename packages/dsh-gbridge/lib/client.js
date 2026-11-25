/**
 * Native In-DSH Desktop & Web Client Module for `dsh-gbridge` (`./client` export).
 *
 * Loaded by `@deepseek-ai/dsh-client-modules` inside BOTH DSH Desktop (Electron)
 * and `dsh web` browsers. Uses ONLY pre-seeded `react` + official DSH CSS theme tokens
 * (`--dsw-alias-*`), so it works natively in Light & Dark themes with ZERO runtime dependencies.
 *
 * Contributes 4 official DSH UI surfaces:
 *   1. `sidebar.panellist` (`id: 'gbridge'`) + `main` (`key: 'gbridge'`): Dedicated pairing dashboard
 *   2. `plugins.bundle.activation` (`key: 'dsh-gbridge'`): Instant QR pairing dialog on plugin enable
 *   3. `plugins.bundle.config` (`key: 'dsh-gbridge'`): Embedded QR & LAN bridge settings inside Plugin Details
 *   4. `settings.section` + `settings.section.icon` (`id: 'gbridge'`): Settings tab for mobile pairing
 */
window.__ModuleLoader__.load({
  id: 'dsh-gbridge',
  factory: function (require) {
    var module = { exports: {} };
    var exports = module.exports;
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' });

    var React = require('react');
    var h = React.createElement;
    var useState = React.useState;
    var useEffect = React.useEffect;
    var useCallback = React.useCallback;

    var PANEL_ID = 'gbridge';
    var BUNDLE_NAME = 'dsh-gbridge';
    var PAIRING_ROUTE = 'api/gbridge/pairing';

    function isZhLocale() {
      try {
        var lang = (document.documentElement.lang || navigator.language || 'zh').toLowerCase();
        return lang.indexOf('zh') === 0;
      } catch (_) {
        return true;
      }
    }

    function transportFetch(path, init) {
      var base = typeof document !== 'undefined' && document.baseURI ? document.baseURI : 'http://127.0.0.1/';
      var url = new URL(path, base);
      var carrier = typeof globalThis !== 'undefined' &&
        globalThis.__DSH_TRANSPORT__ &&
        typeof globalThis.__DSH_TRANSPORT__.fetch === 'function'
        ? globalThis.__DSH_TRANSPORT__.fetch
        : globalThis.fetch.bind(globalThis);
      return carrier(url, Object.assign({ credentials: 'same-origin' }, init || {}));
    }

    async function parseJsonSafe(res) {
      var text = await res.text();
      if (!text) return null;
      try {
        return JSON.parse(text);
      } catch (_err) {
        return null;
      }
    }

    async function fetchPairingState() {
      var res = await transportFetch(PAIRING_ROUTE, { method: 'GET' });
      var data = await parseJsonSafe(res);
      if (!res.ok) {
        throw new Error((data && data.error && data.error.message) || ('HTTP ' + res.status));
      }
      if (!data) throw new Error('Invalid pairing response');
      return data;
    }

    async function mutatePairingState(body) {
      var res = await transportFetch(PAIRING_ROUTE, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      });
      var data = await parseJsonSafe(res);
      if (!res.ok) {
        throw new Error((data && data.error && data.error.message) || ('HTTP ' + res.status));
      }
      if (!data) throw new Error('Invalid pairing response');
      return data;
    }

    function copyTextViaTextarea(text) {
      return new Promise(function (resolve, reject) {
        try {
          var ta = document.createElement('textarea');
          ta.value = text;
          ta.style.position = 'fixed';
          ta.style.opacity = '0';
          document.body.appendChild(ta);
          ta.select();
          var ok = document.execCommand('copy');
          document.body.removeChild(ta);
          if (ok) resolve();
          else reject(new Error('copy command rejected'));
        } catch (err) {
          reject(err);
        }
      });
    }

    function copyTextSafe(text) {
      if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
        return navigator.clipboard.writeText(text).catch(function () {
          return copyTextViaTextarea(text);
        });
      }
      return copyTextViaTextarea(text);
    }

    function GrassBagGlyph(props) {
      var size = (props && props.size) || 18;
      return h(
        'svg',
        {
          width: size,
          height: size,
          viewBox: '0 0 24 24',
          fill: 'none',
          stroke: 'currentColor',
          strokeWidth: 1.8,
          strokeLinecap: 'round',
          strokeLinejoin: 'round',
          'aria-hidden': 'true',
        },
        h('rect', { x: 6, y: 2.5, width: 12, height: 19, rx: 3 }),
        h('path', { d: 'M10 18h4' }),
        h('path', { d: 'M9.5 10.5c1-2.5 3-3.5 5-3.5-.3 2.5-1.5 4.2-4.2 4.5' })
      );
    }

    function QrCodeBox(props) {
      var qr = props.qr;
      var boxSize = props.size || 200;
      var zh = props.zh;
      var loading = Boolean(props.loading);
      if (!qr || !qr.pathData || !qr.viewBoxSize) {
        return h(
          'div',
          {
            style: {
              width: boxSize + 'px',
              height: boxSize + 'px',
              borderRadius: '16px',
              background: 'var(--dsw-alias-bg-layer-2, rgba(127,127,127,0.08))',
              border: '1px dashed var(--dsw-alias-border-l2, rgba(127,127,127,0.25))',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              textAlign: 'center',
              padding: '16px',
              fontSize: '12px',
              color: 'var(--dsw-alias-label-tertiary, #64748b)',
            },
          },
          loading
            ? (zh ? '正在加载配对二维码…' : 'Loading pairing QR code…')
            : (zh ? '开启局域网桥接后将在此显示扫码二维码' : 'Enable LAN Bridge to display QR code')
        );
      }
      return h(
        'div',
        {
          style: {
            background: '#ffffff',
            borderRadius: '18px',
            padding: '12px',
            border: '1px solid rgba(15,23,42,0.10)',
            boxShadow: '0 8px 24px rgba(0,0,0,0.06)',
            display: 'inline-flex',
            flexDirection: 'column',
            alignItems: 'center',
            gap: '8px',
          },
        },
        h(
          'svg',
          {
            width: boxSize,
            height: boxSize,
            viewBox: '0 0 ' + qr.viewBoxSize + ' ' + qr.viewBoxSize,
            shapeRendering: 'crispEdges',
            style: { display: 'block', borderRadius: '8px' },
          },
          h('rect', { width: qr.viewBoxSize, height: qr.viewBoxSize, fill: '#ffffff' }),
          h('path', { d: qr.pathData, fill: '#0f172a' })
        ),
        h(
          'div',
          {
            style: {
              fontSize: '11.5px',
              fontWeight: 500,
              color: '#475569',
            },
          },
          zh ? '手机打开 GrassBag → 扫码连接' : 'Open GrassBag on phone → Scan QR'
        )
      );
    }

    function PairingDashboard(props) {
      var compact = Boolean(props && props.compact);
      var zh = isZhLocale();
      var stateTuple = useState(null);
      var data = stateTuple[0];
      var setData = stateTuple[1];
      var errTuple = useState('');
      var errorMsg = errTuple[0];
      var setErrorMsg = errTuple[1];
      var busyTuple = useState(false);
      var busy = busyTuple[0];
      var setBusy = busyTuple[1];
      var selTuple = useState(0);
      var selectedIdx = selTuple[0];
      var setSelectedIdx = selTuple[1];
      var toastTuple = useState('');
      var toast = toastTuple[0];
      var setToast = toastTuple[1];
      var portInputTuple = useState('');
      var portInput = portInputTuple[0];
      var setPortInput = portInputTuple[1];

      var mountedRef = React.useRef(true);
      var toastTimerRef = React.useRef(null);
      var portInitializedRef = React.useRef(false);
      var reqSeqRef = React.useRef(0);
      var busyRef = React.useRef(false);

      var notify = useCallback(function (msg) {
        if (!mountedRef.current) return;
        setToast(msg);
        if (toastTimerRef.current) clearTimeout(toastTimerRef.current);
        toastTimerRef.current = setTimeout(function () {
          if (!mountedRef.current) return;
          setToast(function (cur) { return cur === msg ? '' : cur; });
        }, 2800);
      }, []);

      var reload = useCallback(async function (silent) {
        if (silent && (busyRef.current || (typeof document !== 'undefined' && document.hidden))) {
          return;
        }
        var seq = ++reqSeqRef.current;
        if (!silent && mountedRef.current) {
          busyRef.current = true;
          setBusy(true);
        }
        try {
          var next = await fetchPairingState();
          if (!mountedRef.current || seq !== reqSeqRef.current) return;
          setData(next);
          setErrorMsg('');
          if (next && next.lan && next.lan.port && (!silent || !portInitializedRef.current)) {
            setPortInput(String(next.lan.port));
            portInitializedRef.current = true;
          }
        } catch (err) {
          if (!mountedRef.current || seq !== reqSeqRef.current) return;
          setErrorMsg(err && err.message ? err.message : String(err));
        } finally {
          if (!silent && mountedRef.current) {
            busyRef.current = false;
            setBusy(false);
          }
        }
      }, []);

      useEffect(function () {
        mountedRef.current = true;
        reload(false);
        var timer = setInterval(function () { reload(true); }, 10000);
        return function () {
          mountedRef.current = false;
          clearInterval(timer);
          if (toastTimerRef.current) clearTimeout(toastTimerRef.current);
        };
      }, [reload]);

      var runAction = async function (payload, okMsg) {
        var seq = ++reqSeqRef.current;
        busyRef.current = true;
        setBusy(true);
        try {
          var next = await mutatePairingState(payload);
          if (!mountedRef.current || seq !== reqSeqRef.current) return;
          setData(next);
          setErrorMsg('');
          if (next && next.lan && next.lan.port) {
            setPortInput(String(next.lan.port));
            portInitializedRef.current = true;
          }
          if (okMsg) notify(okMsg);
        } catch (err) {
          if (!mountedRef.current || seq !== reqSeqRef.current) return;
          notify((zh ? '操作失败：' : 'Failed: ') + (err && err.message ? err.message : String(err)));
        } finally {
          if (mountedRef.current) {
            busyRef.current = false;
            setBusy(false);
          }
        }
      };

      var explicitTheme = typeof document !== 'undefined' && document.documentElement
        ? (document.documentElement.getAttribute('data-theme') || '').toLowerCase()
        : '';
      var isDarkUi = typeof window !== 'undefined' && (
        explicitTheme === 'dark' ||
        (explicitTheme !== 'light' && (
          (document.documentElement && document.documentElement.classList.contains('dark')) ||
          (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches)
        ))
      );
      var accentInk = isDarkUi ? '#2dd4bf' : '#0f766e';
      var accentSoft = isDarkUi ? 'rgba(45,212,191,0.16)' : 'rgba(15,118,110,0.14)';

      var endpoints = (data && Array.isArray(data.endpoints)) ? data.endpoints : [];
      var safeIdx = selectedIdx < endpoints.length ? selectedIdx : 0;
      var activeEp = endpoints[safeIdx] || null;
      var isShared = data && data.mode === 'shared-webserver';
      var lanActive = data && data.mode === 'lan-bridge' && data.lan && data.lan.listening;
      var isReachable = Boolean(isShared || lanActive);

      var statusText = !data
        ? (zh ? '正在检测网络状态…' : 'Detecting network…')
        : isShared
          ? (zh
              ? '复用当前 DSH Web 端口 :' + (data.activePort || '--') + ' · 零额外端口'
              : 'Sharing DSH Web port :' + (data.activePort || '--') + ' · Zero extra port')
          : lanActive
            ? (zh
                ? '内置零冲突局域网桥接 · 端口 :' + data.lan.port + (data.portConflictAvoided ? '（已自动避让冲突端口）' : '')
                : 'Built-in LAN Bridge · Port :' + data.lan.port)
            : (zh ? '局域网桥接未开启（仅本机回环）' : 'LAN Bridge paused (loopback only)');

      var cardStyle = {
        background: 'var(--dsw-alias-settings-card-fill, var(--dsw-alias-bg-layer-1, rgba(127,127,127,0.05)))',
        border: '1px solid var(--dsw-alias-settings-card-stroke, var(--dsw-alias-border-l2, rgba(127,127,127,0.18)))',
        borderRadius: 'var(--dsw-radius-xl, 18px)',
        padding: compact ? '16px' : '22px',
        fontFamily: 'var(--dsw-font-family, -apple-system, BlinkMacSystemFont, sans-serif)',
        color: 'var(--dsw-alias-label-primary, inherit)',
      };

      var btnStyle = function (primary) {
        return {
          display: 'inline-flex',
          alignItems: 'center',
          gap: '6px',
          padding: '8px 14px',
          borderRadius: 'var(--dsw-radius-md, 10px)',
          border: primary ? 'none' : '1px solid var(--dsw-alias-border-l2, rgba(127,127,127,0.24))',
          background: primary ? '#0f766e' : 'var(--dsw-alias-bg-layer-2, transparent)',
          color: primary ? '#ffffff' : 'var(--dsw-alias-label-primary, inherit)',
          fontSize: '12.5px',
          fontWeight: 600,
          cursor: busy ? 'default' : 'pointer',
          opacity: busy ? 0.6 : 1,
        };
      };

      return h(
        'div',
        { style: cardStyle },
        // Header row
        h(
          'div',
          {
            style: {
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              gap: '12px',
              flexWrap: 'wrap',
              marginBottom: '16px',
            },
          },
          h(
            'div',
            { style: { display: 'flex', alignItems: 'center', gap: '11px' } },
            h(
              'div',
              {
                style: {
                  width: '38px',
                  height: '38px',
                  borderRadius: '12px',
                  background: 'linear-gradient(135deg, #34d399, #0f766e)',
                  color: '#ffffff',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  flexShrink: 0,
                },
              },
              h(GrassBagGlyph, { size: 20 })
            ),
            h(
              'div',
              null,
              h(
                'div',
                { style: { fontSize: compact ? '15px' : '17px', fontWeight: 700 } },
                zh ? 'GrassBag 手机扫码配对' : 'GrassBag Mobile Pairing'
              ),
              h(
                'div',
                { style: { fontSize: '12px', color: 'var(--dsw-alias-label-tertiary, #64748b)', marginTop: '2px' } },
                data
                  ? ((data.hostName || 'DSH') + ' · dsh-gbridge v' + data.bridgeVersion + ' · ' + (zh ? '已连设备 ' : 'Connected ') + (data.connectedClients || 0))
                  : (zh ? '官方零冲突连接助手' : 'Official zero-conflict companion')
              )
            )
          ),
          h(
            'span',
            {
              style: {
                display: 'inline-flex',
                alignItems: 'center',
                gap: '6px',
                padding: '5px 11px',
                borderRadius: '999px',
                fontSize: '12px',
                fontWeight: 600,
                background: isReachable ? 'rgba(21,128,61,0.14)' : 'rgba(217,119,6,0.14)',
                color: isReachable ? '#16a34a' : '#d97706',
              },
            },
            h('span', {
              style: {
                width: '7px',
                height: '7px',
                borderRadius: '50%',
                background: 'currentColor',
              },
            }),
            statusText
          )
        ),

        errorMsg
          ? h(
              'div',
              {
                style: {
                  padding: '10px 12px',
                  borderRadius: '10px',
                  background: 'rgba(220,38,38,0.10)',
                  color: '#ef4444',
                  fontSize: '12.5px',
                  marginBottom: '12px',
                },
              },
              (zh ? '读取配对状态失败：' : 'Pairing status error: ') + errorMsg
            )
          : null,

        // Main grid: QR code + Details & Controls
        h(
          'div',
          {
            style: {
              display: 'flex',
              flexWrap: 'wrap',
              gap: '20px',
              alignItems: 'flex-start',
            },
          },
          h(QrCodeBox, { qr: activeEp && activeEp.qr, size: compact ? 176 : 204, zh: zh, loading: !data && !errorMsg }),
          h(
            'div',
            { style: { flex: '1 1 260px', minWidth: '240px' } },
            // Network interface pills
            endpoints.length > 0
              ? h(
                  'div',
                  { style: { marginBottom: '12px' } },
                  h(
                    'div',
                    { style: { fontSize: '11.5px', fontWeight: 600, color: 'var(--dsw-alias-label-tertiary, #64748b)', marginBottom: '6px' } },
                    zh ? '选择局域网 / Tailscale 地址' : 'Select LAN / Tailscale Address'
                  ),
                  h(
                    'div',
                    { style: { display: 'flex', flexWrap: 'wrap', gap: '6px' } },
                    endpoints.map(function (ep, idx) {
                      var active = idx === safeIdx;
                      return h(
                        'button',
                        {
                          key: ep.ip + ':' + ep.iface,
                          type: 'button',
                          onClick: function () { setSelectedIdx(idx); },
                          style: {
                            padding: '5px 10px',
                            borderRadius: '9px',
                            fontSize: '12px',
                            fontWeight: 600,
                            cursor: 'pointer',
                            border: active
                              ? ('1px solid ' + accentInk)
                              : '1px solid var(--dsw-alias-border-l2, rgba(127,127,127,0.22))',
                            background: active ? accentSoft : 'transparent',
                            color: active ? accentInk : 'var(--dsw-alias-label-secondary, inherit)',
                          },
                        },
                        (ep.label || ep.iface) + ' · ' + ep.ip
                      );
                    })
                  )
                )
              : null,

            // Pairing URL box
            h(
              'div',
              {
                style: {
                  padding: '10px 12px',
                  borderRadius: '12px',
                  border: '1px solid var(--dsw-alias-border-l2, rgba(127,127,127,0.2))',
                  background: 'var(--dsw-alias-bg-layer-2, rgba(127,127,127,0.05))',
                  marginBottom: '12px',
                },
              },
              h(
                'div',
                { style: { fontSize: '11px', fontWeight: 600, color: 'var(--dsw-alias-label-tertiary, #64748b)', marginBottom: '4px' } },
                zh ? '配对链接（扫码自动识别，也可复制粘贴）' : 'Pairing URL (scan QR or paste in GrassBag)'
              ),
              h(
                'div',
                {
                  style: {
                    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
                    fontSize: '12px',
                    wordBreak: 'break-all',
                    lineHeight: 1.45,
                  },
                },
                activeEp
                  ? activeEp.url
                  : (zh ? '暂未检测到局域网连接入口，请点击下方「开启局域网桥接」' : 'No LAN endpoint active yet. Enable LAN Bridge below.')
              )
            ),

            // Action buttons
            h(
              'div',
              { style: { display: 'flex', flexWrap: 'wrap', gap: '8px' } },
              activeEp
                ? h(
                    'button',
                    {
                      type: 'button',
                      disabled: busy,
                      style: btnStyle(true),
                      onClick: function () {
                        copyTextSafe(activeEp.url).then(
                          function () { notify(zh ? '已复制配对链接到剪贴板' : 'Pairing link copied'); },
                          function () { notify(zh ? '复制失败，请手动选中复制' : 'Copy failed'); }
                        );
                      },
                    },
                    zh ? '复制配对链接' : 'Copy Pairing Link'
                  )
                : null,
              data && data.token
                ? h(
                    'button',
                    {
                      type: 'button',
                      disabled: busy,
                      style: btnStyle(false),
                      onClick: function () {
                        copyTextSafe(data.token).then(
                          function () { notify(zh ? '已复制访问令牌' : 'Token copied'); },
                          function () { notify(zh ? '复制失败' : 'Copy failed'); }
                        );
                      },
                    },
                    zh ? '复制令牌' : 'Copy Token'
                  )
                : null,
              data && (data.canRotateToken !== undefined ? data.canRotateToken : data.mode === 'lan-bridge')
                ? h(
                    'button',
                    {
                      type: 'button',
                      disabled: busy,
                      style: btnStyle(false),
                      onClick: function () {
                        runAction({ action: 'rotateToken' }, zh ? '已重置令牌并更新二维码' : 'Token rotated');
                      },
                    },
                    zh ? '重置令牌' : 'Rotate Token'
                  )
                : null,
              data && !isShared
                ? h(
                    'button',
                    {
                      type: 'button',
                      disabled: busy,
                      style: btnStyle(!(data.lan && data.lan.enabled)),
                      onClick: function () {
                        var nextEnabled = !(data.lan && data.lan.enabled);
                        runAction(
                          { action: 'setLanEnabled', enabled: nextEnabled },
                          nextEnabled
                            ? (zh ? '已开启零冲突局域网桥接' : 'LAN Bridge enabled')
                            : (zh ? '已暂停局域网桥接' : 'LAN Bridge paused')
                        );
                      },
                    },
                    data.lan && data.lan.enabled
                      ? (zh ? '暂停局域网桥接' : 'Pause LAN Bridge')
                      : (zh ? '开启局域网桥接' : 'Enable LAN Bridge')
                  )
                : null,
              h(
                'button',
                {
                  type: 'button',
                  disabled: busy,
                  style: btnStyle(false),
                  onClick: function () { reload(false); },
                },
                zh ? '刷新状态' : 'Refresh'
              )
            ),

            // Optional zero-conflict port selector for Desktop / loopback LAN Bridge
            !compact && data && !isShared && data.lan && data.lan.enabled
              ? h(
                  'div',
                  {
                    style: {
                      marginTop: '12px',
                      display: 'flex',
                      alignItems: 'center',
                      gap: '8px',
                      flexWrap: 'wrap',
                      fontSize: '12px',
                      color: 'var(--dsw-alias-label-secondary, #475569)',
                    },
                  },
                  h('span', null, zh ? '桥接端口（冲突自动顺延）：' : 'Bridge Port (auto-avoids conflict):'),
                  h('input', {
                    type: 'number',
                    min: 1024,
                    max: 65535,
                    value: portInput,
                    onChange: function (e) { setPortInput(e.target.value); },
                    style: {
                      width: '88px',
                      padding: '5px 8px',
                      borderRadius: '8px',
                      border: '1px solid var(--dsw-alias-border-l2, rgba(127,127,127,0.25))',
                      background: 'var(--dsw-alias-bg-layer-1, transparent)',
                      color: 'var(--dsw-alias-label-primary, inherit)',
                      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
                      fontSize: '12px',
                    },
                  }),
                  h(
                    'button',
                    {
                      type: 'button',
                      disabled: busy,
                      style: btnStyle(false),
                      onClick: function () {
                        var p = Number(portInput);
                        if (!Number.isInteger(p) || p < 1024 || p > 65535) {
                          notify(zh ? '请输入 1024-65535 之间的端口号' : 'Enter a port between 1024 and 65535');
                          return;
                        }
                        runAction({ action: 'setLanPort', port: p }, zh ? '已切换监听端口' : 'Port updated');
                      },
                    },
                    zh ? '应用端口' : 'Apply Port'
                  )
                )
              : null,

            toast
              ? h(
                  'div',
                  {
                    style: {
                      marginTop: '10px',
                      fontSize: '12px',
                      fontWeight: 600,
                      color: accentInk,
                    },
                  },
                  toast
                )
              : null
          )
        ),

        // Compact guidance footer
        h(
          'div',
          {
            style: {
              marginTop: '14px',
              paddingTop: '12px',
              borderTop: '1px solid var(--dsw-alias-border-l2, rgba(127,127,127,0.16))',
              fontSize: '12px',
              lineHeight: 1.55,
              color: 'var(--dsw-alias-label-tertiary, #64748b)',
            },
          },
          zh
            ? '无需另开第二套 dsh web 服务：本插件直接复用当前 DeepSeek Harness 实例的全部会话、模型与工作区；在 dsh web 下直接共享现有端口，在桌面端自动避让冲突端口。'
            : 'No duplicate dsh web process needed: shares this running DeepSeek Harness instance directly, reuses dsh web port when reachable, and auto-avoids port conflicts on Desktop.'
        )
      );
    }

    function MainPairingPage() {
      return h(
        'div',
        {
          style: {
            maxWidth: '820px',
            margin: '0 auto',
            padding: '28px 24px 48px',
            width: '100%',
            boxSizing: 'border-box',
          },
        },
        h(PairingDashboard, { compact: false })
      );
    }

    function ActivationCard(props) {
      var zh = isZhLocale();
      var onDismiss = props && props.onDismiss;
      var onOpenDetails = props && props.onOpenDetails;
      return h(
        'div',
        { style: { padding: '8px 0' } },
        h(PairingDashboard, { compact: true }),
        (onDismiss || onOpenDetails)
          ? h(
              'div',
              { style: { display: 'flex', justifyContent: 'flex-end', gap: '8px', marginTop: '12px' } },
              onOpenDetails
                ? h(
                    'button',
                    {
                      type: 'button',
                      onClick: onOpenDetails,
                      style: {
                        padding: '7px 13px',
                        borderRadius: '9px',
                        border: '1px solid var(--dsw-alias-border-l2, rgba(127,127,127,0.24))',
                        background: 'transparent',
                        color: 'var(--dsw-alias-label-primary, inherit)',
                        fontSize: '12.5px',
                        fontWeight: 600,
                        cursor: 'pointer',
                      },
                    },
                    zh ? '查看插件详情' : 'Plugin Details'
                  )
                : null,
              onDismiss
                ? h(
                    'button',
                    {
                      type: 'button',
                      onClick: onDismiss,
                      style: {
                        padding: '7px 14px',
                        borderRadius: '9px',
                        border: 'none',
                        background: '#0f766e',
                        color: '#ffffff',
                        fontSize: '12.5px',
                        fontWeight: 600,
                        cursor: 'pointer',
                      },
                    },
                    zh ? '完成' : 'Done'
                  )
                : null
            )
          : null
      );
    }

    function BundleConfigView() {
      return h('div', { style: { marginTop: '8px' } }, h(PairingDashboard, { compact: false }));
    }

    function SettingsSectionView() {
      return h('div', { style: { padding: '4px 0 16px' } }, h(PairingDashboard, { compact: false }));
    }

    exports.inject = ['slots'];
    exports.apply = function apply(ctx) {
      var safeInject = function (slotName, registerFn) {
        try {
          if (ctx && ctx.slots && typeof ctx.slots.inject === 'function') {
            ctx.slots.inject(slotName, registerFn);
          }
        } catch (_) {}
      };

      // 1. Dedicated Sidebar entry + Main panel page ("手机连接 / GrassBag")
      safeInject('main', function () {
        return ctx.slots.register({ name: 'main', key: PANEL_ID }, MainPairingPage);
      });
      safeInject('sidebar.panellist', function () {
        return ctx.slots.register(
          {
            name: 'sidebar.panellist',
            id: PANEL_ID,
            order: 50,
            label: function () { return isZhLocale() ? '手机连接' : 'GrassBag'; },
          },
          GrassBagGlyph
        );
      });

      // 2. Immediate QR pairing card on plugin activation & inside Plugin Details
      safeInject('plugins.bundle.activation', function () {
        return ctx.slots.register(
          { name: 'plugins.bundle.activation', key: BUNDLE_NAME },
          ActivationCard
        );
      });
      safeInject('plugins.bundle.config', function () {
        return ctx.slots.register(
          { name: 'plugins.bundle.config', key: BUNDLE_NAME },
          BundleConfigView
        );
      });

      // 3. Settings section inside DSH Settings dialog
      safeInject('settings.section', function () {
        return ctx.slots.register(
          {
            name: 'settings.section',
            id: PANEL_ID,
            order: 85,
            label: function () { return isZhLocale() ? 'GrassBag 手机连接' : 'GrassBag Mobile'; },
          },
          SettingsSectionView
        );
      });
      safeInject('settings.section.icon', function () {
        return ctx.slots.register(
          { name: 'settings.section.icon', id: PANEL_ID, order: 85 },
          GrassBagGlyph
        );
      });
    };

    return module.exports;
  },
});
