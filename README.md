# sbx Claude Tokyo

在 WSL2 Ubuntu 环境中，把 Docker Sandboxes 的 `claude-wsl` 沙箱配置成东京时区、本地化 Chrome 以及可直接使用的 Claude Code 运行环境。

这个仓库记录三件事：

- `sbx` 在 WSL Ubuntu 上安装、排障、创建 `claude-wsl` 的过程。
- `claude-wsl` 内 Claude Code 的登录与日常使用方式。
- 可选的 Chrome + noVNC 图形栈，用于沙箱内浏览器检查或备用网页登录。

> 说明：这里是本地化、隔离运行和可视化排障环境记录，不用于规避服务条款、地区限制或服务端风控。

## 当前状态

沙箱内环境验证结果：

```json
{"timeZone":"Asia/Tokyo","locale":"ja","languages":["ja","en-US","en"],"offset":-540}
```

Claude Code 登录状态已确认：

```json
{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"pro"}
```

实际登录方式不是 noVNC：登录命令在 `sbx` 终端打印 URL，移动端 iOS Safari 无痕模式打开 URL 完成账号登录，再把网页给出的 code 粘回终端，提示 `Login successful`。

## 正常使用 Claude Code

从 Windows Terminal 打开 Ubuntu/WSL 后，直接重新附着到已有沙箱：

```bash
sbx run --name claude-wsl
```

这不是“一次只跑一条命令”，而是进入 `claude-wsl` 里已经配置好的 Claude agent 会话。

如果想先拿到一个普通 Linux shell，再自己运行 `claude`：

```bash
sbx exec -it -w /home/roshan/sbx-claude-workspace claude-wsl bash
claude
```

一次性命令仍然可以用，例如检查登录状态：

```bash
sbx exec claude-wsl sh -lc 'claude auth status --json'
```

常用参数也可以透传给 Claude：

```bash
sbx run --name claude-wsl -- --continue
```

## Claude 登录流程

如果以后需要重新登录，不要让 `claude auth login` 自动桥接宿主 Chrome。使用：

```bash
sbx exec -it -e SBX_NO_DISPLAY=1 claude-wsl sh -lc 'claude auth login --claudeai'
```

然后：

1. 复制终端打印的登录 URL。
2. 用移动端 iOS Safari 无痕模式打开 URL 并登录 Claude.ai 订阅账号。
3. 如果网页给 code，把 code 粘回终端的 `Paste code here if prompted >`。
4. 看到 `Login successful` 后检查状态。

```bash
sbx exec claude-wsl sh -lc 'claude auth status --json'
```

## 可选 noVNC

noVNC 访问链路：

```text
Windows Chrome -> WSL IP:6080 -> sbx port publish -> claude-wsl:6080 -> websockify -> x11vnc -> Xvfb :99 -> Chrome
```

安装依赖：

```bash
./scripts/install-claude-tokyo-browser.sh claude-wsl
```

启动 noVNC：

```bash
./scripts/start-claude-tokyo-novnc.sh claude-wsl
```

启动脚本会创建宿主侧 `tmux` 会话 `sbx-claude-novnc` 来保留 `sbx exec -it`，否则 Docker Sandboxes 可能在 exec 客户端退出后停止沙箱。

脚本会输出类似：

```text
Open from Windows:
  http://172.28.55.163:6080/vnc.html?autoconnect=1&resize=remote
```

WSL IP 每次重启后可能变化，可用下面命令查看：

```bash
hostname -I
```

当前 noVNC 没有密码，`0.0.0.0:6080` 只适合临时本机使用。用完建议关闭：

```bash
./scripts/stop-claude-tokyo-novnc.sh claude-wsl
```

需要停止整个沙箱：

```bash
sbx stop claude-wsl
```

## 仓库内容

- `docs/sbx-安装部署记录-WSL-Ubuntu22.04.md`：完整安装、排障和本次 Claude 登录记录。
- `docs/sbx-cli-help/`：本次采集的 `sbx` CLI 帮助输出。
- `dependencies/apt-packages.txt`：沙箱内安装依赖清单。
- `dependencies/google-chrome-deb.url`：Chrome `.deb` 下载地址。
- `docs/references.md`：官方文档和本次参考链接。
- `scripts/`：可重复执行的安装、启动、停止脚本。
