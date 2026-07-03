# sbx Claude Tokyo

在 WSL2 Ubuntu 环境中，把 Docker Sandboxes 的 Claude 沙箱配置成东京时区、本地化环境以及可直接使用的 Claude Code 运行环境。

这个仓库记录这些事：

- `sbx` 在 WSL Ubuntu 上安装、排障、创建 `claude-wsl` 的过程。
- `claude-wsl` 内 Claude Code 的登录与日常使用方式。
- `claude-gh-ceec` 挂载 `/home/roshan/Developer/gh-ceec` 后的东京环境修复和实时 tmux 使用方式。
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

当前用于 `gh-ceec` 项目的沙箱：

```text
claude-gh-ceec -> /home/roshan/Developer/gh-ceec
```

`claude-gh-ceec` 已修正为东京持久环境：

```json
{"timeZone":"Asia/Tokyo","locale":"ja-JP","offsetMinutes":-540}
```

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

## gh-ceec 项目沙箱

`gh-ceec` 使用单独的 sandbox，不复用 `claude-wsl`，因为 `sbx` 的 workspace 是创建 sandbox 时绑定的：

```bash
sbx create --name claude-gh-ceec claude /home/roshan/Developer/gh-ceec
```

实时查看 Claude Code 输出并对话：

```bash
tmux attach -t claude-gh-ceec
```

从 tmux 里脱离但不停止会话：

```text
Ctrl-b d
```

如果要手动重开这个实时会话：

```bash
tmux kill-session -t claude-gh-ceec 2>/dev/null || true
tmux new-session -d -s claude-gh-ceec 'cd /home/roshan/Developer/gh-ceec && sbx run --name claude-gh-ceec'
```

进入沙箱 shell：

```bash
sbx exec -it -w /home/roshan/Developer/gh-ceec claude-gh-ceec bash
```

`claude-gh-ceec` 是 direct mount，Claude 在沙箱内修改的就是 WSL2 本地 `gh-ceec` 工作树。

`gh-license-management` 没有新建第二个 Claude sandbox，而是通过宿主 WSL bind mount 放进同一个 `claude-gh-ceec`：

```text
/home/roshan/Developer/gh-ceec/.sbx-workspaces/gh-license-management
  -> /home/roshan/Developer/gh-license-management
```

WSL 重启后如果 mount 消失，重新执行：

```bash
mkdir -p /home/roshan/Developer/gh-ceec/.sbx-workspaces/gh-license-management
grep -qxF '.sbx-workspaces/' /home/roshan/Developer/gh-ceec/.git/info/exclude || \
  printf '\n.sbx-workspaces/\n' >> /home/roshan/Developer/gh-ceec/.git/info/exclude
sudo mount --bind /home/roshan/Developer/gh-license-management \
  /home/roshan/Developer/gh-ceec/.sbx-workspaces/gh-license-management
tmux kill-session -t claude-gh-ceec 2>/dev/null || true
sbx stop claude-gh-ceec
sbx exec claude-gh-ceec sh -lc 'ls /home/roshan/Developer/gh-ceec/.sbx-workspaces/gh-license-management | sed -n "1,20p"'
```

注意：第一次创建 `claude-gh-ceec` 后曾发现它是 `UTC/POSIX`，不是东京环境；已停止当时的 tmux 会话，写入 `/etc/sandbox-persistent.sh`、`/etc/localtime`、`/etc/timezone` 并重启验证。后续使用前可快速检查：

```bash
sbx exec claude-gh-ceec sh -lc 'date; node -e "console.log(Intl.DateTimeFormat().resolvedOptions())"'
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

- `docs/sbx-安装部署记录-WSL-Ubuntu22.04.md`：完整安装、排障、Claude 登录和 `gh-ceec` 沙箱记录。
- `docs/sbx-cli-help/`：本次采集的 `sbx` CLI 帮助输出。
- `dependencies/apt-packages.txt`：沙箱内安装依赖清单。
- `dependencies/google-chrome-deb.url`：Chrome `.deb` 下载地址。
- `docs/references.md`：官方文档和本次参考链接。
- `scripts/`：可重复执行的安装、启动、停止脚本。
