# 在电脑上准备 GrassBag 手机配对

在电脑浏览器打开本页，按你当前使用的 DeepSeek Harness 方式任选一步即可（所有复制按钮都在电脑端直接点击）。

---

## 方式一：我用 DSH Desktop（桌面端，推荐）

1. 在电脑上打开 **DeepSeek Harness Desktop**。
2. 点击界面里的 **「插件」→「添加插件」**。
3. 复制下方任意一条插件包地址，粘贴进「添加插件」输入框并确认安装：

国内加速源（推荐）：

```text
https://gh-proxy.com/https://github.com/moduqishi/grassbag/releases/latest/download/dsh-gbridge.tgz
```

GitHub 直连备用源：

```text
https://github.com/moduqishi/grassbag/releases/latest/download/dsh-gbridge.tgz
```

4. 启用后，左侧栏会出现 **「手机连接」**（首次启用也会直接弹出配对二维码）。
5. 打开手机上的 **GrassBag → 连接电脑 → 扫电脑上的二维码**，扫完后电脑端会显示「已连接到你的手机」。

> 不需要额外启动 `dsh web`，也不会占用或冲突 DSH 现有端口。

---

## 方式二：我已运行 `dsh web`（免插件直连）

1. **如果你已经启动了 `dsh web`**：
   - 查看终端输出的完整启动链接（形如 `http://192.168.x.x:3080/?token=...`）。
   - 如果输出里的地址是 `127.0.0.1` 或 `localhost`，说明当前只允许电脑本机访问，需要用下方命令绑定局域网 IP 重新启动。
2. **用局域网 IP 启动 `dsh web`**：

macOS 终端：

```bash
dsh web --host $(ipconfig getifaddr $(route -n get default 2>/dev/null | awk "/interface:/{print \$2}" | head -n1) 2>/dev/null || ipconfig getifaddr en0) --no-open
```

Windows PowerShell：

```powershell
$ip=(Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Sort-Object RouteMetric | Select-Object -First 1 | Get-NetIPAddress -AddressFamily IPv4).IPAddress; dsh web --host $ip --no-open
```

Linux 终端：

```bash
dsh web --host $(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}') --no-open
```

3. 把终端打印出的完整 `http://<局域网IP>:<端口>/?token=...` 链接发到手机，在手机 **GrassBag → 连接电脑 → 粘贴连接链接** 即可直接打开会话。
