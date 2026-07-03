# sbx Claude Tokyo

在 WSL2 Ubuntu 环境中，把 Docker Sandboxes 的 `claude-wsl` 沙箱配置成可视化的东京本地化 Claude Code 登录环境。

这个仓库记录两件事：

- `sbx` 在 WSL Ubuntu 上安装、排障、创建 `claude-wsl` 的过程。
- 在 `claude-wsl` 内安装 Chrome + noVNC，使 Claude网页登录发生在沙箱内，而不是宿主机 Chrome。

> 说明：这里是本地化与可视化登录环境记录，不用于规避服务条款、地区限制或服务端风控。

## 当前方案

沙箱内环境验证结果：

```json
{"timeZone":"Asia/Tokyo","locale":"ja","languages":["ja","en-US","en"],"offset":-540}
```

noVNC 访问链路：

```text
Windows Chrome -> WSL IP:6080 -> sbx port publish -> claude-wsl:6080 -> websockify -> x11vnc -> Xvfb :99 -> Chrome
```

## 快速使用

安装依赖：

```bash
./scripts/install-claude-tokyo-browser.sh claude-wsl
```

启动 noVNC：

```bash
./scripts/start-claude-tokyo-novnc.sh claude-wsl
```

脚本会输出类似：

```text
Open from Windows:
  http://172.28.55.163:6080/vnc.html?autoconnect=1&resize=remote
```

WSL IP 每次重启后可能变化，可用下面命令查看：

```bash
hostname -I
```

## Claude 登录

不要让 `claude auth login` 自动桥接宿主 Chrome。使用：

```bash
sbx exec -it -e SBX_NO_DISPLAY=1 claude-wsl sh -lc 'claude auth login --claudeai'
```

然后：

1. 复制终端打印的登录 URL。
2. 打开 noVNC 里的沙箱内 Chrome。
3. 把 URL 粘到沙箱内 Chrome 地址栏。
4. 登录同一个 Claude.ai 订阅账号。
5. 如果页面给 code，把 code 粘回终端。

检查登录状态：

```bash
sbx exec claude-wsl sh -lc 'claude auth status --json'
```

## 停止与收口

当前 noVNC 没有密码，`0.0.0.0:6080` 只适合临时本机使用。完成登录后建议关闭：

```bash
./scripts/stop-claude-tokyo-novnc.sh claude-wsl
```

需要停止整个沙箱：

```bash
sbx stop claude-wsl
```

## 仓库内容

- `docs/sbx-安装部署记录-WSL-Ubuntu22.04.md`：完整安装、排障和本次 noVNC 追加记录。
- `docs/sbx-cli-help/`：本次采集的 `sbx` CLI 帮助输出。
- `dependencies/apt-packages.txt`：沙箱内安装依赖清单。
- `dependencies/google-chrome-deb.url`：Chrome `.deb` 下载地址。
- `docs/references.md`：官方文档和本次参考链接。
- `scripts/`：可重复执行的安装、启动、停止脚本。

