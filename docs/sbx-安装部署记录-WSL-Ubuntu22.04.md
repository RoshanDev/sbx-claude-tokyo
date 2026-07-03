# sbx 安装部署记录（Windows + WSL Ubuntu 22.04）

## 1. 目标

在 `Windows + WSL2 + Ubuntu 22.04.5` 环境中安装并跑通 Docker `sbx`，用于把 Claude Code 放进隔离沙箱里运行，不升级 `wslc`，不切换到 Docker Desktop。

## 2. 环境信息

- Windows: `10.0.26200.8655`
- WSL: `2.6.1.0`
- Linux 发行版: `Ubuntu 22.04.5 LTS (jammy)`
- 内核: `6.6.87.2-microsoft-standard-WSL2`
- `sbx` 版本: `v0.34.0`

## 3. 最终可用状态

- `sbx version` 正常
- `sbx ls` 正常
- `sbx policy ls` 正常
- `sandboxd` 可以启动
- `sbx policy init balanced` 已完成
- `sbx create shell /tmp` 已成功
- `sbx create --name claude-wsl claude /home/roshan/sbx-claude-workspace` 已成功
- `sbx exec claude-wsl sh -lc 'command -v claude && claude --version'` 已成功，沙箱内 `Claude Code` 可启动
- 宿主机侧 `sbx` 已通过 `~/.local/bin/sbx` 包装脚本默认绕开 WSL 的 Secret Service / D-Bus 卡顿问题

当前会话里，`sbx` 控制面和 `Claude` 模板运行面都已经验证通过，但还剩一个需要人工完成的业务动作：

- 沙箱里的 `claude -p "Reply with OK only."` 当前会返回 `Not logged in · Please run /login`
- 因此 `Claude Code` 已经进沙箱并可执行，但首次使用仍需在沙箱内完成一次 `claude auth login`，或者后续按官方方式注入 `CLAUDE_CODE_OAUTH_TOKEN`

说明：当前这套修复不是官方一键无脑安装态，实际包含三层兼容处理：

1. 绕开 Linux keyring，走 headless / file-backed auth
2. 补一份支持 `--tar` 的 `mkfs.erofs`
3. 用官方 `rockylinux8.rpm` 里的兼容运行时替换通用 Linux tarball 中对 `Ubuntu 22.04` 不兼容的 `libsailor.so` / `shim` 组件

## 4. 实际安装步骤

### 4.1 前置检查

确认当前环境满足基本运行条件：

```bash
lsb_release -a
id -nG
ls -l /dev/kvm
lsmod | grep kvm
command -v sbx || true
```

关键结论：

- `KVM` 模块已加载
- `/dev/kvm` 存在
- 当前用户最开始不在 `kvm` 组
- `sbx` 初始未安装

### 4.2 配置 Docker 仓库

先加官方源：

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
```

备注：`jammy` 仓库里当时没有可直接安装的 `docker-sbx` 包，所以后续没有走 `apt install docker-sbx`。

### 4.3 用 Docker 官方 release tarball 安装 sbx

下载并安装 `sbx`：

```bash
curl -L -o DockerSandboxes-linux.tar.gz https://github.com/docker/sbx-releases/releases/download/v0.34.0/DockerSandboxes-linux.tar.gz
tar -xzf DockerSandboxes-linux.tar.gz
cd docker-sbx
sudo PREFIX=/usr/local ./install.sh
sudo usermod -aG kvm "$USER"
```

校验：

```bash
/usr/local/bin/sbx version
```

安装完成后需要重新开一个 WSL 终端，或者执行：

```bash
newgrp kvm
```

否则当前 shell 看不到新加入的 `kvm` 组。

## 5. 第一个坑：`sbx login` 卡在 Secret Service / GNOME Keyring

### 5.1 现象

执行：

```bash
sbx login
```

报错类似：

```text
failed to open secretservice session: The name org.freedesktop.secrets was not provided by any .service files
```

后面即使弹出 `Unlock Login Keyring`，由于历史 keyring 状态不一致，也容易一直解不开。

### 5.2 原因

在 WSL 里：

- `sbx` 默认想走 Linux Secret Service
- 但无完整桌面会话时，这条链容易半残
- `gnome-keyring` 可能能拉起服务，但默认 collection 不可用
- 旧的 `login.keyring` 还可能让流程持续弹错密码框

### 5.3 处理过程

装了这些包做定位：

```bash
sudo apt-get install -y gnome-keyring libsecret-tools
```

确认过：

- `org.freedesktop.secrets` 能挂上 D-Bus
- 但 keyring collection 初始化依然不稳定

最终没有继续强依赖 keyring，而是切到 `sbx` 的无 keychain 回退路径。

### 5.4 最终可用登录方式

使用无桌面、无 DBus 的 headless 登录：

```bash
env -u DBUS_SESSION_BUS_ADDRESS -u DISPLAY SBX_NO_DISPLAY=1 sbx login --username <docker-username> --password-stdin
```

输入密码后，需要给 stdin 一个 EOF；交互 shell 里等价于按一次：

```text
Ctrl-D
```

成功后会看到类似提示：

```text
Signed in as <docker-username>.
No keychain detected - this secret will be stored in an encrypted file on disk
```

认证文件最终落在：

```text
~/.config/com.docker.sandboxes/com.docker.sandboxes-auth/
```

## 6. 第二个坑：`sandboxd` 启动失败，报 `io.containerd.transfer.v1` 插件不存在

### 6.1 现象

执行：

```bash
sbx ls
```

最初会报：

```text
ERROR: failed to start backend in-process
...
failed to get "io.containerd.transfer.v1" plugin: no plugins registered for io.containerd.transfer.v1
```

### 6.2 日志定位

关键日志文件：

```text
~/.local/state/sandboxes/sandboxes/sandboxd/daemon.log
```

日志里先后暴露出两个兼容性问题：

1. `sbx` 自带的 `/usr/local/libexec/mkfs.erofs` 需要更高版本 `glibc`，在 `Ubuntu 22.04` 上跑不起来。
2. `Ubuntu 22.04` 仓库里的 `erofs-utils 1.4` 太老，不支持 `--tar`，即使换系统版也还是会被 containerd 判定为不可用。

日志里出现过两种典型错误：

```text
failed to run mkfs.erofs --help
```

和：

```text
mkfs.erofs does not support tar mode (--tar option)
```

### 6.3 中间尝试

先装系统版 `erofs-utils`：

```bash
sudo apt-get install -y erofs-utils
```

这能解决 `glibc` 不兼容，但解决不了 `--tar` 缺失，因为 jammy 自带版本还是太旧。

### 6.4 最终修复

编译一份新版 `erofs-utils`，只拿 `mkfs.erofs` 供 `sbx` 使用。

安装构建依赖：

```bash
sudo apt-get install -y build-essential autoconf automake libtool pkg-config uuid-dev liblz4-dev zlib1g-dev libzstd-dev
```

下载并编译 `erofs-utils 1.9.1`：

```bash
mkdir -p /tmp/erofs-build
cd /tmp/erofs-build
curl -L -o erofs-utils-1.9.1.tar.gz https://github.com/erofs/erofs-utils/archive/refs/tags/v1.9.1.tar.gz
tar -xzf erofs-utils-1.9.1.tar.gz
cd erofs-utils-1.9.1
./autogen.sh
./configure --disable-fuse --without-selinux
make -j"$(nproc)"
```

确认新版本支持 `--tar`：

```bash
./mkfs/mkfs.erofs --help | rg -- --tar
```

安装到兼容路径，并让 `sbx` 使用它：

```bash
sudo install -d /usr/local/libexec/sbx-compat
sudo install -m 0755 ./mkfs/mkfs.erofs /usr/local/libexec/sbx-compat/mkfs.erofs
sudo mv /usr/local/libexec/mkfs.erofs /usr/local/libexec/mkfs.erofs.orig
sudo ln -sf /usr/local/libexec/sbx-compat/mkfs.erofs /usr/local/libexec/mkfs.erofs
```

### 6.5 修复后验证

停止旧 daemon 并重试：

```bash
sbx daemon stop || true
sbx ls
```

最终返回：

```text
No sandboxes found.
Launch one: sbx run claude
```

说明运行层已经恢复正常。

### 6.6 后续追查：`TTRPC connection refused` 的真正根因是 `libsailor.so` 的 `glibc` 版本过高

在 `mkfs.erofs` 修好后，`sbx create shell /tmp` 一度仍报：

```text
failed to start shim: failed to create TTRPC connection ... connect: connection refused
```

继续看 `daemon.log` 后发现，`containerd-shim-nerdbox-v1` 启动 VM 前就已经异常退出。  
进一步检查：

```bash
ldd /usr/local/libexec/lib/libsailor.so
```

会看到类似：

```text
/lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.39' not found
```

这说明：

- `DockerSandboxes-linux.tar.gz` 里的通用 Linux 运行时并不适配 `Ubuntu 22.04`
- `sbx` CLI 本身能跑，不代表 `shim + sailor + kernel/initrd` 这一套运行时也能在本机工作

### 6.7 最终修复：改用官方 `rockylinux8.rpm` 里的兼容运行时

先安装提取 RPM 所需工具：

```bash
sudo apt-get install -y rpm2cpio
```

下载并解开官方同版本 RPM：

```bash
mkdir -p /tmp/sbx-rpm-test
cd /tmp/sbx-rpm-test
curl -L -o DockerSandboxes-linux-amd64-rockylinux8.rpm https://github.com/docker/sbx-releases/releases/download/v0.34.0/DockerSandboxes-linux-amd64-rockylinux8.rpm
mkdir -p extract
cd extract
rpm2cpio ../DockerSandboxes-linux-amd64-rockylinux8.rpm | cpio -idmv
```

备份当前安装，再替换兼容运行时：

```bash
stamp=$(date +%F-%H%M%S)
backup_dir=/usr/local/libexec/sbx-backup-$stamp

sudo mkdir -p "$backup_dir/lib"
sudo install -m 0755 /usr/local/bin/sbx "$backup_dir/sbx"
sudo install -m 0755 /usr/local/libexec/containerd-shim-nerdbox-v1 "$backup_dir/containerd-shim-nerdbox-v1"
sudo install -m 0644 /usr/local/libexec/lib/libsailor.so "$backup_dir/lib/libsailor.so"
sudo install -m 0644 /usr/local/libexec/nerdbox-kernel-x86_64 "$backup_dir/nerdbox-kernel-x86_64"
sudo install -m 0644 /usr/local/libexec/nerdbox-initrd-x86_64 "$backup_dir/nerdbox-initrd-x86_64"

sudo install -m 0755 /tmp/sbx-rpm-test/extract/usr/bin/sbx /usr/local/bin/sbx
sudo install -m 0755 /tmp/sbx-rpm-test/extract/usr/libexec/containerd-shim-nerdbox-v1 /usr/local/libexec/containerd-shim-nerdbox-v1
sudo install -m 0644 /tmp/sbx-rpm-test/extract/usr/libexec/lib/libsailor.so /usr/local/libexec/lib/libsailor.so
sudo install -m 0644 /tmp/sbx-rpm-test/extract/usr/libexec/nerdbox-kernel-x86_64 /usr/local/libexec/nerdbox-kernel-x86_64
sudo install -m 0644 /tmp/sbx-rpm-test/extract/usr/libexec/nerdbox-initrd-x86_64 /usr/local/libexec/nerdbox-initrd-x86_64
```

说明：

- 上面替换的是 `sbx`、`shim`、`libsailor.so`、`nerdbox-kernel`、`nerdbox-initrd`
- 前面自己编译好的 `mkfs.erofs` 继续保留即可，不必回退
- 本机一次实际备份目录是：`/usr/local/libexec/sbx-backup-2026-07-02-140058`

### 6.8 WSL 下 `sbx` 命令本身仍可能再次触发 keyring，最终做法是放一个 wrapper

即使登录时用了 headless 方式，`sbx version` / `sbx ls` 在 WSL 下仍可能因为继承了：

```text
XDG_RUNTIME_DIR=/run/user/1000
```

自动连上：

```text
/run/user/1000/bus
```

然后再次去走 `org.freedesktop.secrets` 的 `Unlock/Prompt` 路径，表现为：

- 命令卡住无输出
- 或再次弹出 `Unlock Login Keyring`

最终可用做法是在 `PATH` 前面放一个包装脚本：

```bash
mkdir -p ~/.local/bin
cat > ~/.local/bin/sbx <<'EOF'
#!/bin/sh
export SBX_NO_DISPLAY=1
export DISPLAY=
export DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/sbx-nonexistent-bus
exec /usr/local/bin/sbx "$@"
EOF
chmod 755 ~/.local/bin/sbx
```

校验：

```bash
command -v sbx
```

应该优先命中：

```text
/home/<user>/.local/bin/sbx
```

### 6.9 如果前一次异常退出，记得清理陈旧的 `sandboxd` pid / socket

如果 `sbx` 明明不崩，但命令长期卡住，可以先检查：

```text
~/.local/state/sandboxes/sandboxes/sandboxd/sandboxd.pid
~/.local/state/sandboxes/sandboxes/sandboxd/sandboxd.sock
~/.local/state/sandboxes/sandboxes/sandboxd/docker.sock
```

当 `sandboxd.pid` 指向的进程已经不存在时，可以把这些旧现场挪走：

```bash
state=~/.local/state/sandboxes/sandboxes/sandboxd
stale_dir="$state/stale-$(date +%F-%H%M%S)"
mkdir -p "$stale_dir"
mv "$state/sandboxd.pid" "$stale_dir/" 2>/dev/null || true
mv "$state/sandboxd.sock" "$stale_dir/" 2>/dev/null || true
mv "$state/docker.sock" "$stale_dir/" 2>/dev/null || true
```

然后再重跑：

```bash
sbx version
sbx ls
```

## 7. 关键文件与落点

### 7.1 认证与状态

```text
~/.config/com.docker.sandboxes/com.docker.sandboxes-auth/
~/.local/state/sandboxes/sandboxes/
~/.local/share/sandboxes/
```

### 7.2 关键二进制

```text
/usr/local/bin/sbx
/usr/local/libexec/containerd-shim-nerdbox-v1
/usr/local/libexec/lib/libsailor.so
/usr/local/libexec/mkfs.erofs
/usr/local/libexec/mkfs.erofs.orig
/usr/local/libexec/sbx-compat/mkfs.erofs
/usr/local/libexec/nerdbox-kernel-x86_64
/usr/local/libexec/nerdbox-initrd-x86_64
```

### 7.3 历史 keyring 备份

```text
~/.local/share/keyrings-backup/
```

### 7.4 WSL 包装脚本与修复现场

```text
~/.local/bin/sbx
~/.config/sandboxes/sandboxes/settings.json
~/.config/sandboxes/sandboxes/settings.json.lock
~/.local/state/sandboxes/sandboxes/sandboxd/stale-*/
/usr/local/libexec/sbx-backup-*/
```

## 8. 经验教训

### 8.1 `Ubuntu 22.04` 不是当前 Linux sbx 的“开箱即用”甜点位

`sbx v0.34.0` 能装上，但运行起来会踩到：

- 自带 `mkfs.erofs` 的 `glibc` 兼容性问题
- 系统仓库 `erofs-utils` 版本过老的问题

如果追求最省事，后续更适合在：

- 更新的 Ubuntu 版本
- 或 Docker 官方明确覆盖更好的发行版

上直接跑。

### 8.2 WSL 里不要强依赖 Linux keyring

这次实践里，headless 文件后端比 Secret Service 稳定得多。  
对 WSL 而言，登录推荐直接用：

```bash
env -u DBUS_SESSION_BUS_ADDRESS -u DISPLAY SBX_NO_DISPLAY=1 sbx login --username <docker-username> --password-stdin
```

### 8.3 出问题先看 `daemon.log`

`sbx` 表面错误信息比较泛，真正能定位到插件、二进制兼容性、运行参数的还是：

```text
~/.local/state/sandboxes/sandboxes/sandboxd/daemon.log
```

### 8.4 `PATH` 看起来没问题，不代表 `sbx` 真会用系统二进制

这次不是简单的“PATH 里找不到命令”，而是 `sbx/containerd` 实际用了它自己的 `libexec` 工具链。  
所以仅仅在 `/bin` 或 `/usr/local/bin` 放工具，不一定能生效；必要时要替换它实际引用的 `libexec` 路径。

### 8.5 `SBX_NO_DISPLAY=1` 不足以完全切断 WSL 的 keyring 路径

仅设置：

```bash
SBX_NO_DISPLAY=1
```

并不足以让 `sbx` 完全放弃 Secret Service。  
只要 `XDG_RUNTIME_DIR` 仍指向 `/run/user/<uid>`，`sbx` 还是可能自动连接用户 D-Bus，再去触发 `org.freedesktop.secrets`。

对 WSL 最稳的做法是：

- 保留 `SBX_NO_DISPLAY=1`
- 同时把 `DBUS_SESSION_BUS_ADDRESS` 指向一个不存在的 socket
- 最简单的是用前面的 `~/.local/bin/sbx` wrapper 固化下来

### 8.6 通用 Linux tarball 不等于适配 `Ubuntu 22.04`

这次最容易误判的一点是：

- `sbx` CLI 可以执行
- `libsailor.so` / `shim` / `kernel` / `initrd` 却不一定兼容当前发行版

在 `Ubuntu 22.04` 上，官方同版本的 `rockylinux8.rpm` 运行时反而比通用 `DockerSandboxes-linux.tar.gz` 更稳。

## 9. 后续使用建议

### 9.1 启动前自检

```bash
command -v sbx
sbx version
sbx ls
sbx policy ls
```

其中：

- `command -v sbx` 最好命中 `~/.local/bin/sbx`
- `sbx ls` 能正常拉起 `sandboxd` 并返回列表，说明宿主机侧基本正常

### 9.2 登录建议

如果已经按上文安装了 `~/.local/bin/sbx` wrapper，日常直接用：

```bash
sbx login --username <docker-username> --password-stdin
```

如果临时绕过 wrapper，仍建议显式写成：

```bash
env -u DBUS_SESSION_BUS_ADDRESS -u DISPLAY SBX_NO_DISPLAY=1 sbx login --username <docker-username> --password-stdin
```

### 9.3 直接启动当前这台机器上的 Claude 沙箱

```bash
sbx run --name claude-wsl
```

### 9.4 进沙箱后的首次 Claude 登录

进到沙箱后，第一次使用要执行：

```bash
claude auth login
```

或者在交互界面里直接输：

```text
/login
```

验证方式：

```bash
claude --version
claude -p "Reply with OK only."
```

如果返回：

```text
Not logged in · Please run /login
```

说明 `sbx` 和 `Claude Code` 本体都已经正常，只差沙箱内首次鉴权。

### 9.5 关于长期 token

如果不想每个新沙箱都手动登录，官方支持在宿主机执行：

```bash
claude setup-token
```

然后通过环境变量 `CLAUDE_CODE_OAUTH_TOKEN` 注入沙箱。  
本记录这次没有自动把长期凭据写进沙箱，只完成了：

- `sbx` 宿主机侧修复
- `Claude` 模板创建与启动验证
- `claude` 命令在沙箱内可执行验证

## 10. Claude Code 关进沙箱的建议步骤

这一节的目标不是“保证不封号”，而是把 `Claude Code` 尽量收敛到一个更稳定、边界更清晰的运行形态里，降低共享号、脚本号、宿主机全暴露、环境画像混乱这些风险。

### 10.1 一次性前置

首次用 `sbx` 之前先做两件事，第三件是 **只有在你走 Anthropic API key 工作流时才需要** 的可选项：

```bash
sbx policy init balanced
sbx login --username <docker-username> --password-stdin

# 可选：仅用于 API key 流程，不是 Claude Code 订阅/OAuth 的必需项
echo "$ANTHROPIC_API_KEY" | sbx secret set -g anthropic
```

说明：

- `balanced` 是官方推荐的初始网络策略
- 如果已安装 `~/.local/bin/sbx` wrapper，普通 `sbx login` 就已经是 headless 路径
- `sbx secret set -g anthropic` 用的是 `sbx` 的代理注入机制，比把 key 直接写进项目目录或 `.env` 更稳
- 但对 `Claude Code` 订阅/OAuth 模式，这一步不是必需项

### 10.2 推荐的沙箱形态

优先用这两种：

1. 代码仓库可直接挂载时：

```bash
sbx create --name my-project claude /path/to/project /path/to/docs:ro
sbx run --name my-project
```

2. 想进一步减少宿主机工作区直接暴露时：

```bash
sbx create --clone --name my-project claude /path/to/project
sbx run --name my-project
```

建议：

- 主项目目录只挂当前仓库，不要把整个 `~`、`/mnt/d`、`/mnt/c` 一股脑挂进去
- 文档、规范、只读参考材料用 `:ro`
- 敏感仓库优先 `--clone`

### 10.3 沙箱内环境统一设置

你要求保留：

- `TZ=Asia/Tokyo`
- 英文 locale

这两项建议只放在 **沙箱内部**，不要改宿主机全局。  
写法也建议当成“沙箱环境整形”，不要当成“保证不封号”的万能键。

#### 方案 A：保守稳定版

如果镜像里不一定有 `en_US.UTF-8`，优先用这组：

```bash
sbx exec my-project sh -lc 'for f in ~/.profile ~/.bashrc; do touch "$f"; grep -q "TZ=Asia/Tokyo" "$f" || cat >> "$f" <<EOF
export TZ=Asia/Tokyo
export LANGUAGE=en_US:en
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
EOF
done'
```

这组的特点：

- `TZ` 固定成东京
- 语言偏好是英文
- 编码层用 `C.UTF-8`，兼容性通常比硬写 `en_US.UTF-8` 更高

#### 方案 B：完整英文 locale 版

如果沙箱镜像里确认已经有 `en_US.UTF-8`，可以改成：

```bash
sbx exec my-project sh -lc 'for f in ~/.profile ~/.bashrc; do touch "$f"; grep -q "TZ=Asia/Tokyo" "$f" || cat >> "$f" <<EOF
export TZ=Asia/Tokyo
export LANGUAGE=en_US:en
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
EOF
done'
```

先检查镜像是否支持：

```bash
sbx exec my-project sh -lc 'locale -a'
```

如果输出里没有 `en_US.utf8` 或 `en_US.UTF-8`，不要硬写，回退到方案 A。

### 10.4 每次进沙箱后的自检

进入沙箱后建议先看四项：

```bash
date
locale
env | rg '^(TZ|LANG|LC_ALL|LANGUAGE)='
pwd
```

目标：

- 时间显示按 `Asia/Tokyo`
- `LANG` / `LC_ALL` / `LANGUAGE` 是你预期的英文组合
- 当前目录只在沙箱工作区里

### 10.5 最小权限原则

建议固定执行：

- 不把 `~/.ssh`、云厂商凭据、宿主机整块主目录挂进去
- 不把长期凭据直接写到项目目录
- 通过 `sbx secret set` 注入服务密钥
- 只挂当前项目和确实需要的只读参考目录

### 10.6 日常使用建议

- 单人单号，不共享
- 优先官方链路，不走野生中转
- 交互式开发用 `Claude Code`
- 长时间批量自动化用 API，不要把订阅版当廉价 API 池
- 重要决策和结果落到仓库文档、issue、commit，不只留在对话里

### 10.7 当前这台机器上的已知风险

截至本次会话，这套 `WSL + Ubuntu 22.04` 环境上已经确认：

- `sbx version`、`sbx login`、`sbx ls`、`sandboxd` 启动可用
- `sbx policy init balanced` 已完成
- `sbx create shell /tmp` 已验证成功
- `sbx create --name claude-wsl claude /home/roshan/sbx-claude-workspace` 已验证成功
- `sbx exec claude-wsl sh -lc 'command -v claude && claude --version'` 已验证成功

当前剩余的已知项不是 `sbx` 运行时故障，而是：

- 沙箱里的 `Claude Code` 仍需单独完成首次登录
- 如果绕过 `~/.local/bin/sbx`，直接调用 `/usr/local/bin/sbx`，仍可能再次触发 WSL 下的 keyring / D-Bus 卡顿
- 这套机器上的修复依赖兼容替换，不适合作为“官方标准安装流程”直接外推到所有发行版

如果后续再撞到类似问题，优先看：

```text
~/.local/state/sandboxes/sandboxes/sandboxd/daemon.log
```

## 11. 2026-07-02 补充：当前机器上的最终操作步骤与使用说明

### 11.1 一次性修复顺序

按这次实际验证结果，`Ubuntu 22.04 + WSL2` 上的稳定顺序是：

1. 安装 `sbx`
2. 让当前用户进入 `kvm` 组
3. 修 `mkfs.erofs`
4. 用 `rockylinux8.rpm` 里的运行时替换 `libsailor.so` / `shim` / `kernel` / `initrd`
5. 放置 `~/.local/bin/sbx` wrapper，彻底绕开 WSL 下的 Secret Service / D-Bus 卡顿

### 11.2 当前机器上已验证通过的最小工作流

创建工作目录并创建 Claude 沙箱：

```bash
mkdir -p /home/roshan/sbx-claude-workspace
sbx create --name claude-wsl claude /home/roshan/sbx-claude-workspace
```

连接沙箱：

```bash
sbx run --name claude-wsl
```

把当前这个 `Claude` 沙箱固定成东京时区：

```bash
sbx exec -u root claude-wsl sh -lc 'printf "export TZ=Asia/Tokyo\n" > /etc/sandbox-persistent.sh && chmod 644 /etc/sandbox-persistent.sh && ln -snf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime && printf "Asia/Tokyo\n" > /etc/timezone'
```

验证时区：

```bash
sbx exec claude-wsl sh -lc 'date && env | rg "^TZ=" && readlink -f /etc/localtime && cat /etc/timezone'
```

本次实际结果应类似：

```text
Thu Jul  2 19:07:02 JST 2026
TZ=Asia/Tokyo
/usr/share/zoneinfo/Asia/Tokyo
Asia/Tokyo
```

进入后首次登录：

```bash
claude auth login
```

或者在 Claude 界面内输入：

```text
/login
```

### 11.3 宿主机侧验证命令

```bash
command -v sbx
sbx version
sbx ls
sbx policy ls
```

预期：

- `command -v sbx` 指向 `~/.local/bin/sbx`
- `sbx version` 能立即返回版本
- `sbx ls` 能正常拉起 `sandboxd`

### 11.4 沙箱侧验证命令

验证模板和 Claude Code 本体：

```bash
sbx exec claude-wsl sh -lc 'command -v claude && claude --version'
```

本次实际输出类似：

```text
/home/agent/.local/bin/claude
2.1.195 (Claude Code)
```

验证时区已经固定为东京：

```bash
sbx exec claude-wsl sh -lc 'date'
```

预期看到：

```text
... JST ...
```

验证 Claude 是否已登录：

```bash
sbx exec claude-wsl sh -lc 'claude -p "Reply with OK only."'
```

如果返回：

```text
Not logged in · Please run /login
```

则说明：

- `sbx` 运行时正常
- `Claude Code` 本体正常
- 只是沙箱里还没完成首次 Claude 鉴权

### 11.5 可选：长期 token 方案

如果希望跳过每个新沙箱里的手动登录，官方文档支持：

```bash
claude setup-token
```

生成长期 token，然后通过环境变量 `CLAUDE_CODE_OAUTH_TOKEN` 注入沙箱。  
这属于凭据管理策略问题，本次记录只确认：

- 官方有这条路
- 当前机器上没有自动落这一步

## 12. 参考链接与材料

- Docker Sandboxes 文档：<https://docs.docker.com/ai/sandboxes/>
- Docker Sandboxes 安装页：<https://docs.docker.com/ai/sandboxes/get-started/>
- Docker sbx release：<https://github.com/docker/sbx-releases/releases/latest>
- Linux 启动失败问题：<https://github.com/docker/sbx-releases/issues/255>
- Claude Code IAM / token 文档：<https://docs.anthropic.com/en/docs/claude-code/iam>
- Claude Code CLI 参考：<https://docs.anthropic.com/en/docs/claude-code/cli-reference>
- erofs-utils：<https://github.com/erofs/erofs-utils>
- 微信参考链接 1：<https://mp.weixin.qq.com/s/j2m563pfhDoIory7G5xz-w>
- 微信参考链接 2：<https://mp.weixin.qq.com/s/lkqKBg8vCadxdcG_Pdskqg>
- 本地参考材料：`D:\Downloads\把 Claude Code 装进笼子里！.pdf`
- 本地参考材料：`D:\Downloads\Claude Code 下蛊投毒！.pdf`

## 13. 一句话结论

这次 `sbx` 在 `WSL + Ubuntu 22.04` 上已经能把 `Claude Code` 真正跑进沙箱，  
但依赖三层兼容修复：绕开 WSL keyring、补 `mkfs.erofs`、再用 `rockylinux8.rpm` 里的兼容运行时替换不兼容的 `libsailor.so` / `shim`。  
现在宿主机侧 `sbx` 已可直接用，沙箱 `claude-wsl` 也已创建成功；真正剩下的只有沙箱内第一次 `claude auth login`。

## 14. 2026-07-03 追加：claude-wsl 内置东京 Chrome + noVNC 登录环境

### 14.1 目标

本次追加目标是让 Claude Code 的网页登录流程也发生在 `claude-wsl` 沙箱内部，而不是通过 `sbx` 的 `xdg-open` 桥接到宿主机 Chrome。

原因：

- `claude-wsl` 内部已经是东京时区，但宿主机浏览器仍可能暴露宿主机的浏览器环境。
- `claude auth login` 默认会调用沙箱内 `/usr/local/bin/xdg-open`。
- `claude-wsl` 的 `xdg-open` 是 `sbx` 桥接脚本，会把 URL 发给宿主机浏览器打开。

边界说明：这里记录的是合法的本地化和可视化登录环境搭建，用于保证沙箱内 CLI、Node、Chrome 的本地环境一致；不记录也不建议任何规避服务条款、地区限制或服务端风控的做法。

### 14.2 当前 Claude 登录状态

检查命令：

```bash
sbx exec claude-wsl sh -lc 'claude auth status --json'
```

本次实际结果：

```json
{
  "loggedIn": false,
  "authMethod": "none",
  "apiProvider": "firstParty"
}
```

说明：

- `claude-wsl` 内 Claude Code 已安装并初始化过配置目录。
- 当前还没有登录 Claude 订阅账号。
- 订阅账号需要通过 `claude auth login --claudeai` 登录同一个 Claude.ai 账号。

### 14.3 沙箱内东京环境核验

基础时间检查：

```bash
sbx exec claude-wsl sh -lc 'date'
```

本次实际结果：

```text
Fri Jul  3 21:32:14 JST 2026
```

系统时区检查：

```bash
sbx exec claude-wsl sh -lc 'printf "TZ=%s\n" "$TZ"; readlink /etc/localtime; cat /etc/timezone'
```

本次确认：

```text
TZ=Asia/Tokyo
/usr/share/zoneinfo/Asia/Tokyo
Asia/Tokyo
```

Node / Intl 检查：

```bash
sbx exec claude-wsl sh -lc 'node -e "const r=Intl.DateTimeFormat().resolvedOptions(); console.log(JSON.stringify({timeZone:r.timeZone, locale:r.locale, offsetMinutes:new Date().getTimezoneOffset(), date:new Date().toString()}, null, 2))"'
```

本次实际结果：

```json
{
  "timeZone": "Asia/Tokyo",
  "locale": "en-US",
  "offsetMinutes": -540,
  "date": "Fri Jul 03 2026 21:34:20 GMT+0900 (Japan Standard Time)"
}
```

### 14.4 安装沙箱内 Chrome 与图形依赖

先安装基础图形、字体、locale 支撑：

```bash
sbx exec -u root claude-wsl sh -lc 'apt-get update'

sbx exec -u root claude-wsl sh -lc '
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    locales fontconfig fonts-noto-cjk xvfb dbus-x11 ca-certificates &&
  locale-gen en_US.UTF-8 ja_JP.UTF-8
'
```

Ubuntu 26.04 模板里的 `chromium-browser` / `firefox` 是 snap 过渡包，不适合这个容器场景。曾尝试 Playwright Chromium：

```bash
sbx exec claude-wsl sh -lc 'PLAYWRIGHT_BROWSERS_PATH="$HOME/.cache/ms-playwright" npx -y playwright@latest install chromium'
```

失败原因：

```text
Blocked by network policy: domain cdn.playwright.dev:443
```

因此改用 Google Chrome 官方 `.deb`：

```bash
sbx exec -u root claude-wsl sh -lc '
  curl -L --fail --show-error \
    --output /tmp/google-chrome-stable_current_amd64.deb \
    https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb &&
  DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/google-chrome-stable_current_amd64.deb
'
```

验证：

```bash
sbx exec claude-wsl sh -lc 'google-chrome --version; locale -a | rg "^(en_US|ja_JP)" || true; fc-match "Noto Sans CJK JP"; fc-match "Noto Sans CJK SC"'
```

本次确认：

```text
Google Chrome 150.0.7871.46
en_US.utf8
ja_JP.utf8
NotoSansCJK-Regular.ttc: "Noto Sans CJK JP" "Regular"
NotoSansCJK-Regular.ttc: "Noto Sans CJK SC" "Regular"
```

### 14.5 沙箱内 Chrome JS 指纹核验

使用 headless Chrome 做本地 JS 环境检查：

```bash
sbx exec claude-wsl sh -lc '
  TZ=Asia/Tokyo LANG=ja_JP.UTF-8 LC_ALL=ja_JP.UTF-8 \
  google-chrome \
    --headless=new \
    --no-sandbox \
    --disable-gpu \
    --disable-dev-shm-usage \
    --disable-background-networking \
    --lang=ja-JP \
    --user-data-dir="$HOME/.cache/chrome-sbx-check" \
    --dump-dom "data:text/html,<script>document.write(JSON.stringify({timeZone:Intl.DateTimeFormat().resolvedOptions().timeZone,locale:Intl.DateTimeFormat().resolvedOptions().locale,languages:navigator.languages,language:navigator.language,offset:new Date().getTimezoneOffset(),date:new Date().toString(),platform:navigator.platform,ua:navigator.userAgent}))</script>"
'
```

本次实际结果中核心字段为：

```json
{
  "timeZone": "Asia/Tokyo",
  "locale": "ja",
  "languages": ["ja", "en-US", "en"],
  "language": "ja",
  "offset": -540,
  "date": "Fri Jul 03 2026 21:46:09 GMT+0900 (日本標準時)",
  "platform": "Linux x86_64"
}
```

### 14.6 安装 noVNC 可视化登录环境

安装 noVNC 组件：

```bash
sbx exec -u root claude-wsl sh -lc '
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    x11vnc novnc websockify openbox
'
```

保持 sandbox 常驻运行：

```bash
sbx run --name claude-wsl --detached
```

说明：这条命令在当前环境里会让 `claude-wsl` 进入 `running` 状态，并返回 sandbox ID。早先尝试过 `sbx exec -d claude-wsl sh -lc 'sleep infinity'`，但该命令在当前环境里容易挂住当前终端，不作为最终推荐写法。

启动 Xvfb、openbox、Chrome、x11vnc、noVNC：

```bash
sbx exec -u root claude-wsl sh -lc 'mkdir -p /tmp/.X11-unix && chown root:root /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix'

sbx exec claude-wsl sh -lc '
  pkill -f "[X]vfb :99" 2>/dev/null || true
  pkill -f "[x]11vnc -display :99" 2>/dev/null || true
  pkill -f "[w]ebsockify --web=/usr/share/novnc 0.0.0.0:6080" 2>/dev/null || true
  pkill -f "[g]oogle-chrome.*\\.chrome-claude-jp" 2>/dev/null || true
  pkill -x openbox 2>/dev/null || true
  rm -f /tmp/sbx-*.log
'

sbx exec claude-wsl sh -lc '
  setsid -f Xvfb :99 -screen 0 1280x900x24 -nolisten tcp -ac >/tmp/sbx-xvfb.log 2>&1
  sleep 1
  DISPLAY=:99 setsid -f openbox >/tmp/sbx-openbox.log 2>&1
  DISPLAY=:99 TZ=Asia/Tokyo LANG=ja_JP.UTF-8 LC_ALL=ja_JP.UTF-8 \
    setsid -f google-chrome \
      --no-sandbox \
      --disable-dev-shm-usage \
      --no-first-run \
      --no-default-browser-check \
      --lang=ja-JP \
      --user-data-dir="$HOME/.chrome-claude-jp" \
      --window-size=1280,900 \
      about:blank >/tmp/sbx-chrome.log 2>&1
  env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE \
    setsid -f x11vnc -display :99 -localhost -nopw -forever -shared -rfbport 5900 >/tmp/sbx-x11vnc.log 2>&1
  setsid -f websockify --web=/usr/share/novnc 0.0.0.0:6080 localhost:5900 >/tmp/sbx-novnc.log 2>&1
'
```

关键点：

- 清理和启动要分成两个 `sbx exec`。如果同一个 `sh -lc` 同时包含 `pkill` 和后面要启动的 `google-chrome` / `websockify`，`pkill -f` 可能匹配当前 shell 的完整命令行并把自己打掉。
- 启动阶段要用 `setsid -f`，否则 `nohup ... &` 仍可能随 `sbx exec` 会话退出被清理，noVNC 会表现为 `Failed to connect to server`。
- `x11vnc` 必须去掉 `WAYLAND_DISPLAY` / `XDG_SESSION_TYPE`，否则会误判成 Wayland 会话并退出。
- `x11vnc` 只监听沙箱内 `localhost:5900`。
- `websockify` 监听沙箱内 `0.0.0.0:6080`，再代理到 `localhost:5900`。

### 14.7 Windows Chrome 访问 noVNC

最初使用：

```bash
sbx ports claude-wsl --publish 6080
```

或默认发布时，`sbx` 会绑定 WSL 侧 loopback：

```text
127.0.0.1:6080 -> 6080/tcp
[::1]:6080 -> 6080/tcp
```

这种情况下 WSL 内部 `curl http://127.0.0.1:6080/vnc.html` 可以通，但 Windows Chrome 可能打不开。

处理方式：改为 IPv4 全地址监听。

```bash
sbx ports claude-wsl --unpublish 127.0.0.1:6080:6080 --unpublish '[::1]:6080:6080'
sbx ports claude-wsl --publish 0.0.0.0:6080:6080/tcp4
```

确认：

```bash
sbx ls
sbx ports claude-wsl --json
hostname -I
curl -sS --max-time 5 "http://$(hostname -I | awk '{print $1}'):6080/vnc.html" | sed -n '1,6p'
```

本次实际 WSL IP：

```text
172.28.55.163
```

Windows Chrome 打开：

```text
http://172.28.55.163:6080/vnc.html?autoconnect=1&resize=remote
```

如果 WSL 重启，IP 可能变化，重新执行：

```bash
hostname -I
```

再用新的 IP 访问。

### 14.8 使用沙箱内 Chrome 完成 Claude 登录

登录命令：

```bash
sbx exec -it -e SBX_NO_DISPLAY=1 claude-wsl sh -lc 'claude auth login --claudeai'
```

`SBX_NO_DISPLAY=1` 的作用：

- 阻止 `sbx` 自动把登录 URL 通过 `xdg-open` 发给宿主机浏览器。
- 让 CLI 在终端里打印登录 URL。

操作流程：

1. 在终端运行上面的 `claude auth login --claudeai`。
2. 复制终端打印的登录 URL。
3. 打开 noVNC 页面。
4. 把登录 URL 粘到 noVNC 里的沙箱内 Chrome 地址栏。
5. 用同一个 Claude.ai 订阅账号登录。
6. 如果网页给出 code，把 code 粘回终端提示。
7. 登录后检查：

```bash
sbx exec claude-wsl sh -lc 'claude auth status --json'
```

### 14.9 安全与清理

当前 noVNC 没有设置密码，并且发布到了 `0.0.0.0:6080`。这适合本机临时登录，不适合长期暴露。

登录完成后建议关闭端口：

```bash
sbx ports claude-wsl --unpublish 0.0.0.0:6080:6080/tcp4
```

或停止 noVNC 相关进程：

```bash
sbx exec claude-wsl sh -lc '
  pkill -f "websockify.*6080" 2>/dev/null || true
  pkill -f "x11vnc.*:99" 2>/dev/null || true
'
```

如果要停止整个 sandbox：

```bash
sbx stop claude-wsl
```

### 14.10 本次新增参考链接

- Docker Sandboxes get started：<https://docs.docker.com/ai/sandboxes/get-started/>
- Docker `sbx` CLI reference：<https://docs.docker.com/reference/cli/sbx/>
- Docker Sandboxes releases：<https://github.com/docker/sbx-releases/releases>
- Docker Sandboxes release notes：<https://docs.docker.com/ai/sandboxes/release-notes/>
- Claude Code authentication：<https://docs.anthropic.com/en/docs/claude-code/iam>
- Claude Code quickstart：<https://docs.anthropic.com/en/docs/claude-code/quickstart>
- 用户提供的浏览器环境检测项目：<https://github.com/LinXiaoTao/FuckClaude>
- 用户提供的本地浏览器环境检测页：<https://damn-claude.jay6697117.deno.net/zh/>
