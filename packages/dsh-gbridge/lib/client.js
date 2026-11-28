/**
 * Native In-DSH Desktop & Web Client Module for `dsh-gbridge` (`./client` export).
 *
 * Loaded by `@deepseek-ai/dsh-client-modules` inside BOTH DSH Desktop (Electron)
 * and `dsh web` browsers. Uses ONLY pre-seeded `react` + official DSH CSS theme tokens
 * (`--dsw-alias-*`), so it works natively in Light & Dark themes with ZERO runtime dependencies.
 *
 * Focused pairing flow:
 * - Default view shows ONLY: recommended QR code, copy pairing link, and live per-pairing
 *   status ("等待手机扫码" / "正在连接你的手机…" / "已连接到你的手机" / explicit LAN error + Retry).
 * - Secondary controls (other NICs, port, token copy/rotate, pause LAN, WS count) are tucked
 *   cleanly inside a collapsible "更多" drawer.
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
      var boxSize = props.size || 208;
      var zh = props.zh;
      var loading = Boolean(props.loading);
      var hasLanErr = Boolean(props.hasLanError);
      if (!qr || !qr.pathData || !qr.viewBoxSize) {
        return h(
          'div',
          {
            style: {
              width: boxSize + 'px',
              height: boxSize + 'px',
              borderRadius: '18px',
              background: 'var(--dsw-alias-bg-layer-2, rgba(127,127,127,0.08))',
              border: '1px dashed var(--dsw-alias-border-l2, rgba(127,127,127,0.25))',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              textAlign: 'center',
              padding: '18px',
              fontSize: '12.5px',
              lineHeight: 1.5,
              color: hasLanErr ? '#ef4444' : 'var(--dsw-alias-label-tertiary, #64748b)',
            },
          },
          loading
            ? (zh ? '正在准备配对二维码…' : 'Preparing QR code…')
            : hasLanErr
              ? (zh ? '局域网服务未启动，请先点击右侧重试' : 'LAN listener failed. Retry on the right.')
              : (zh ? '开启手机配对后将在此显示二维码' : 'Enable pairing to show QR code')
        );
      }
      return h(
        'div',
        {
          style: {
            background: '#ffffff',
            borderRadius: '20px',
            padding: '14px',
            border: '1px solid rgba(15,23,42,0.10)',
            boxShadow: '0 10px 28px rgba(0,0,0,0.07)',
            display: 'inline-flex',
            flexDirection: 'column',
            alignItems: 'center',
            gap: '9px',
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
              fontSize: '12px',
              fontWeight: 500,
              color: '#475569',
            },
          },
          zh ? '手机打开 GrassBag → 连接电脑 → 扫码' : 'Open GrassBag on phone → Scan QR'
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
      var moreTuple = useState(false);
      var showMore = moreTuple[0];
      var setShowMore = moreTuple[1];
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
        // Poll every 3s while visible so the computer confirms "已连接到你的手机" promptly.
        var timer = setInterval(function () { reload(true); }, 3000);
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
      var lanError = (data && data.lan && !data.lan.listening && data.lan.error) ? String(data.lan.error) : '';
      var ps = (data && data.pairingSession) ? data.pairingSession : null;
      var pairStatus = lanError ? 'error' : ((ps && ps.status) || 'waiting');
      var pairedLabel = (ps && ps.deviceLabel) || (zh ? '你的手机' : 'your phone');

      var cardStyle = {
        background: 'var(--dsw-alias-settings-card-fill, var(--dsw-alias-bg-layer-1, rgba(127,127,127,0.05)))',
        border: '1px solid var(--dsw-alias-settings-card-stroke, var(--dsw-alias-border-l2, rgba(127,127,127,0.18)))',
        borderRadius: 'var(--dsw-radius-xl, 18px)',
        padding: compact ? '18px' : '24px',
        fontFamily: 'var(--dsw-font-family, -apple-system, BlinkMacSystemFont, sans-serif)',
        color: 'var(--dsw-alias-label-primary, inherit)',
      };

      var btnStyle = function (primary) {
        return {
          display: 'inline-flex',
          alignItems: 'center',
          justifyContent: 'center',
          gap: '6px',
          padding: '9px 15px',
          borderRadius: 'var(--dsw-radius-md, 10px)',
          border: primary ? 'none' : '1px solid var(--dsw-alias-border-l2, rgba(127,127,127,0.24))',
          background: primary ? '#0f766e' : 'var(--dsw-alias-bg-layer-2, transparent)',
          color: primary ? '#ffffff' : 'var(--dsw-alias-label-primary, inherit)',
          fontSize: '13px',
          fontWeight: 600,
          cursor: busy ? 'default' : 'pointer',
          opacity: busy ? 0.6 : 1,
        };
      };

      // Live per-pairing status banner
      var statusBannerBg = 'rgba(15,118,110,0.10)';
      var statusBannerFg = accentInk;
      var statusHeadline = zh ? '等待手机扫码连接' : 'Waiting for your phone to scan';
      var statusDetail = zh
        ? '扫码完成后，这里会自动更新为已连接状态。'
        : 'This panel will confirm automatically once your phone connects.';
      if (!data && !errorMsg) {
        statusHeadline = zh ? '正在准备配对…' : 'Preparing pairing…';
        statusDetail = zh ? '正在检查本机网络与连接服务。' : 'Checking local network and pairing service.';
      } else if (lanError) {
        statusBannerBg = 'rgba(220,38,38,0.12)';
        statusBannerFg = '#ef4444';
        statusHeadline = zh ? '局域网监听启动失败' : 'Failed to start LAN listener';
        statusDetail = lanError;
      } else if (!isReachable) {
        statusBannerBg = 'rgba(217,119,6,0.12)';
        statusBannerFg = '#d97706';
        statusHeadline = zh ? '手机配对已暂停' : 'Mobile pairing paused';
        statusDetail = zh ? '重新开启后即可生成二维码供手机扫码。' : 'Enable pairing to show a scannable QR code.';
      } else if (pairStatus === 'connected') {
        statusBannerBg = 'rgba(21,128,61,0.14)';
        statusBannerFg = '#16a34a';
        statusHeadline = zh ? ('已连接到' + pairedLabel) : ('Connected to ' + pairedLabel);
        statusDetail = zh
          ? '手机已成功建立实时会话连接，现在可以直接在手机上对话。'
          : 'Your phone is connected and ready to open sessions.';
      } else if (pairStatus === 'connecting') {
        statusBannerBg = 'rgba(14,165,233,0.14)';
        statusBannerFg = isDarkUi ? '#38bdf8' : '#0284c7';
        statusHeadline = zh ? '正在连接你的手机…' : 'Connecting to your phone…';
        statusDetail = zh
          ? '已识别扫码请求，正在完成实时通道握手。'
          : 'Scan detected, completing live handshake.';
      }

      return h(
        'div',
        { style: cardStyle },
        // Clean Header
        h(
          'div',
          {
            style: {
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              gap: '12px',
              marginBottom: '18px',
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
                { style: { fontSize: compact ? '15.5px' : '17.5px', fontWeight: 700 } },
                zh ? 'GrassBag 手机连接' : 'GrassBag Mobile Pairing'
              ),
              h(
                'div',
                { style: { fontSize: '12px', color: 'var(--dsw-alias-label-tertiary, #64748b)', marginTop: '2px' } },
                data ? (data.hostName || 'DSH') : (zh ? '手机配对面板' : 'Mobile pairing panel')
              )
            )
          )
        ),

        errorMsg
          ? h(
              'div',
              {
                style: {
                  padding: '10px 12px',
                  borderRadius: '12px',
                  background: 'rgba(220,38,38,0.10)',
                  color: '#ef4444',
                  fontSize: '12.5px',
                  marginBottom: '14px',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  gap: '10px',
                },
              },
              h('span', null, (zh ? '读取配对状态失败：' : 'Pairing status error: ') + errorMsg),
              h(
                'button',
                { type: 'button', style: btnStyle(false), onClick: function () { reload(false); } },
                zh ? '重试' : 'Retry'
              )
            )
          : null,

        // Focused Main Grid: Recommended QR + Live Status + Copy Link
        h(
          'div',
          {
            style: {
              display: 'flex',
              flexWrap: 'wrap',
              gap: '22px',
              alignItems: 'center',
            },
          },
          h(QrCodeBox, {
            qr: activeEp && activeEp.qr,
            size: compact ? 180 : 210,
            zh: zh,
            loading: !data && !errorMsg,
            hasLanError: Boolean(lanError),
          }),
          h(
            'div',
            { style: { flex: '1 1 250px', minWidth: '230px' } },
            // Live pairing confirmation card
            h(
              'div',
              {
                style: {
                  padding: '12px 14px',
                  borderRadius: '14px',
                  background: statusBannerBg,
                  marginBottom: '14px',
                },
              },
              h(
                'div',
                {
                  style: {
                    display: 'flex',
                    alignItems: 'center',
                    gap: '8px',
                    fontSize: '14px',
                    fontWeight: 700,
                    color: statusBannerFg,
                  },
                },
                h('span', {
                  style: {
                    width: '8px',
                    height: '8px',
                    borderRadius: '50%',
                    background: 'currentColor',
                    flexShrink: 0,
                  },
                }),
                statusHeadline
              ),
              h(
                'div',
                {
                  style: {
                    marginTop: '5px',
                    fontSize: '12px',
                    lineHeight: 1.45,
                    color: 'var(--dsw-alias-label-secondary, #475569)',
                  },
                },
                statusDetail
              )
            ),

            // Primary action(s): Copy Pairing Link (or Retry on LAN error / Enable if paused)
            h(
              'div',
              { style: { display: 'flex', flexWrap: 'wrap', gap: '8px', alignItems: 'center' } },
              lanError
                ? h(
                    'button',
                    {
                      type: 'button',
                      disabled: busy,
                      style: btnStyle(true),
                      onClick: function () {
                        runAction({ action: 'setLanEnabled', enabled: true }, zh ? '已重新启动局域网连接服务' : 'LAN listener restarted');
                      },
                    },
                    zh ? '重试启动' : 'Retry'
                  )
                : (!isReachable && data && !isShared)
                  ? h(
                      'button',
                      {
                        type: 'button',
                        disabled: busy,
                        style: btnStyle(true),
                        onClick: function () {
                          runAction({ action: 'setLanEnabled', enabled: true }, zh ? '已开启手机配对' : 'Pairing enabled');
                        },
                      },
                      zh ? '开启手机配对' : 'Enable Pairing'
                    )
                  : activeEp
                    ? h(
                        'button',
                        {
                          type: 'button',
                          disabled: busy,
                          style: btnStyle(true),
                          onClick: function () {
                            copyTextSafe(activeEp.url).then(
                              function () { notify(zh ? '已复制配对链接，可直接粘贴到手机 GrassBag' : 'Pairing link copied'); },
                              function () { notify(zh ? '复制失败，请手动选中复制' : 'Copy failed'); }
                            );
                          },
                        },
                        zh ? '复制配对链接' : 'Copy Pairing Link'
                      )
                    : null,
              pairStatus === 'connected'
                ? h(
                    'button',
                    {
                      type: 'button',
                      disabled: busy,
                      style: btnStyle(false),
                      onClick: function () {
                        runAction({ action: 'newPairingCode' }, zh ? '已刷新二维码，等待新设备扫码' : 'Fresh QR code ready');
                      },
                    },
                    zh ? '配对新设备' : 'Pair Another Device'
                  )
                : null,
              h(
                'button',
                {
                  type: 'button',
                  style: Object.assign({}, btnStyle(false), { padding: '9px 12px' }),
                  onClick: function () { setShowMore(function (v) { return !v; }); },
                },
                showMore ? (zh ? '收起更多' : 'Less') : (zh ? '更多' : 'More')
              )
            ),

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

        // Collapsible "更多" drawer: NIC switcher, custom port, copy/rotate token, pause LAN, technical metadata
        showMore
          ? h(
              'div',
              {
                style: {
                  marginTop: '18px',
                  paddingTop: '16px',
                  borderTop: '1px solid var(--dsw-alias-border-l2, rgba(127,127,127,0.16))',
                  display: 'flex',
                  flexDirection: 'column',
                  gap: '12px',
                },
              },
              endpoints.length > 1
                ? h(
                    'div',
                    null,
                    h(
                      'div',
                      { style: { fontSize: '11.5px', fontWeight: 600, color: 'var(--dsw-alias-label-tertiary, #64748b)', marginBottom: '6px' } },
                      zh ? '切换网卡地址（默认已推荐当前局域网地址）' : 'Switch Network Adapter'
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

              activeEp
                ? h(
                    'div',
                    {
                      style: {
                        padding: '9px 11px',
                        borderRadius: '10px',
                        border: '1px solid var(--dsw-alias-border-l2, rgba(127,127,127,0.2))',
                        background: 'var(--dsw-alias-bg-layer-2, rgba(127,127,127,0.05))',
                        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
                        fontSize: '11.5px',
                        wordBreak: 'break-all',
                      },
                    },
                    activeEp.url
                  )
                : null,

              h(
                'div',
                { style: { display: 'flex', flexWrap: 'wrap', gap: '8px' } },
                h(
                  'button',
                  {
                    type: 'button',
                    disabled: busy,
                    style: btnStyle(false),
                    onClick: function () {
                      runAction({ action: 'newPairingCode' }, zh ? '已刷新二维码' : 'QR code refreshed');
                    },
                  },
                  zh ? '刷新二维码' : 'Refresh QR'
                ),
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
                        style: btnStyle(false),
                        onClick: function () {
                          var nextEnabled = !(data.lan && data.lan.enabled);
                          runAction(
                            { action: 'setLanEnabled', enabled: nextEnabled },
                            nextEnabled
                              ? (zh ? '已开启局域网桥接' : 'LAN Bridge enabled')
                              : (zh ? '已暂停局域网桥接' : 'LAN Bridge paused')
                          );
                        },
                      },
                      data.lan && data.lan.enabled
                        ? (zh ? '暂停局域网桥接' : 'Pause LAN Bridge')
                        : (zh ? '开启局域网桥接' : 'Enable LAN Bridge')
                    )
                  : null
              ),

              !compact && data && !isShared && data.lan && data.lan.enabled
                ? h(
                    'div',
                    {
                      style: {
                        display: 'flex',
                        alignItems: 'center',
                        gap: '8px',
                        flexWrap: 'wrap',
                        fontSize: '12px',
                        color: 'var(--dsw-alias-label-secondary, #475569)',
                      },
                    },
                    h('span', null, zh ? '监听端口（冲突自动顺延）：' : 'Port (auto-avoids conflict):'),
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

              data
                ? h(
                    'div',
                    {
                      style: {
                        fontSize: '11.5px',
                        color: 'var(--dsw-alias-label-tertiary, #64748b)',
                        display: 'flex',
                        flexWrap: 'wrap',
                        gap: '12px',
                      },
                    },
                    h('span', null, (zh ? '端口：' : 'Port: ') + (data.activePort || '--')),
                    h('span', null, (zh ? '当前在线连接数：' : 'Active streams: ') + (data.connectedClients || 0)),
                    h('span', null, 'dsh-gbridge v' + data.bridgeVersion)
                  )
                : null
            )
          : null
      );
    }

    function MainPairingPage() {
      return h(
        'div',
        {
          style: {
            maxWidth: '760px',
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
