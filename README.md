# Vernal Dawn VPS 工具箱（vps-optimize）

```
 _    ____________  _   _____    __    ____  ___ _       ___   __
| |  / / ____/ __ \/ | / /   |  / /   / __ \/   | |     / / | / /
| | / / __/ / /_/ /  |/ / /| | / /   / / / / /| | | /| / /  |/ /
| |/ / /___/ _, _/ /|  / ___ |/ /___/ /_/ / ___ | |/ |/ / /|  /
|___/_____/_/ |_/_/ |_/_/  |_/_____/_____/_/  |_|__/|__/_/ |_/
```

新 VPS 初始化与优化的交互式脚本：**菜单里逐项挑选、每项单独执行、改之前先确认、改过的文件自动备份**。
适用于 Ubuntu 22.04 / 24.04、Debian 12，并对**甲骨文云（Oracle Cloud）**镜像做了专门处理。

[English](#english)

## 一键运行

复制这一条到终端执行（普通账号也可以，脚本会自动用 sudo 提权）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/insffxx/vps-optimize/main/vps-optimize.sh)
```

想先看代码再运行，可以先下载到本地：

```bash
curl -fsSLO https://raw.githubusercontent.com/insffxx/vps-optimize/main/vps-optimize.sh
less vps-optimize.sh
sudo bash vps-optimize.sh
```

第一次打开会询问是否安装快捷命令，装好后**输入 `ins` 就能启动**（每次自动更新到最新版）。

| 命令 | 作用 |
|---|---|
| `sudo bash vps-optimize.sh` | 打开菜单，可以一次输入多个编号（如 `1 2 5 9`） |
| `sudo bash vps-optimize.sh auto` | **一键推荐优化**：一路按回车，把不会锁死自己的项目全部做完 |
| `sudo bash vps-optimize.sh 9` | 直接执行第 9 项 |
| `sudo bash vps-optimize.sh uninstall` | 卸载（可选同时撤销所有改动） |
| `ins` / `ins status` / `ins auto` | 装好快捷命令后的简写 |
| `sudo bash vps-optimize.sh status` | 只查看当前状态，不做任何修改 |
| `sudo bash vps-optimize.sh list` | 列出全部项目 |
| `sudo DRY_RUN=1 bash vps-optimize.sh` | 预演模式：只打印将要做的改动 |

## 菜单项目

菜单里已经做好的项目会标 ✅，还没做的标 ⬜。

| # | 项目 | 做什么 |
|---|---|---|
| s | 查看当前状态 | 系统、内存、防火墙类型、SSH 配置、对外监听端口、最近登录（只读） |
| 1 | 添加 SSH 公钥 | 粘贴公钥 → 校验格式 → 写入 `authorized_keys`（拒绝误贴私钥） |
| 2 | SSH 加固 | 禁止 root 登录、禁止密码登录、最多试 3 次、关闭 X11 转发；**没检测到公钥会拒绝执行**，防止把自己锁在外面 |
| 3 | 更换 SSH 端口 | 先**新旧端口同时开放** → 你新开终端测试 → 再关闭旧端口；**10 分钟内不确认就自动回滚**；同时更新防火墙和 fail2ban |
| 4 | IPv6 防火墙补齐 | 甲骨文镜像的 IPv6 默认全开，按 IPv4 已放行的端口生成对等的 `rules.v6` |
| 5 | fail2ban | SSH 防暴力破解（10 分钟内失败 5 次，封禁 1 小时），自动适配 Ubuntu 24.04 的 journal 日志 |
| 6 | 关闭多余服务 | 逐个询问是否关闭 rpcbind、cups、avahi 等服务；甲骨文的监控 agent 保留不动 |
| 7 | 系统更新 | `apt upgrade`，保留你改过的配置文件，需要重启时会提示 |
| 8 | 自动安全更新 | unattended-upgrades，只装安全补丁，**不会自动重启** |
| 9 | BBR | 拥塞控制改为 bbr + fq |
| 10 | 内核网络安全参数 | SYN 防护、拒绝 ICMP 重定向和源路由等；做代理/转发的机器会用宽松的反向路径校验 |
| 11 | swap | 按内存大小建议 swap 容量，开机自动挂载，swappiness 设为 10 |
| 12 | 时区 | 例如 Asia/Shanghai |
| 13 | 主机名 | 同步修改 `/etc/hosts`，并防止 cloud-init 在重启后改回 |
| 14 | 日志上限 | 限制 journald 的磁盘占用 |
| 15 | 加密 DNS | systemd-resolved + DNS over TLS，可选 Cloudflare / Google 或阿里 / 腾讯（面向国内）；网卡下发的 DNS 不再作为默认；解析失败会自动恢复 |
| 16 | 放行端口 | 给新装的服务在系统防火墙放行 TCP/UDP 端口（IPv4 + IPv6，写入开机规则），并提醒你去云厂商网页放行 |
| 17 | IPv4 优先 | 修改 `/etc/gai.conf`，域名同时有 IPv4/IPv6 时优先走 IPv4，解决 IPv6 绕路造成的卡顿（IPv6 仍然可用） |
| 18 | 时间同步 | 检查 chrony / systemd-timesyncd，没有就开启自动对时（日志、证书、两步验证都依赖准确时间） |
| 19 | 最小化防火墙 | 没有防火墙的机器启用 UFW：默认拒绝入站，只放行 SSH 和你指定的端口；**5 分钟内不确认能登录就自动关闭**；甲骨文这类已有 iptables 规则的机器会跳过，不混用 |
| 20 | 快捷命令 | 安装 `ins`，以后输入它就能打开菜单（自动拉取最新版，联网失败时用本机缓存） |
| 21 | 系统清理 | 清软件包缓存、无用依赖和旧内核、超出上限的日志、snap 旧版本、10 天没用过的临时文件；不会删光日志 |
| 22 | 网络性能调优 | 按内存自动设置收发缓冲、连接队列、TCP Fast Open、端口范围、最大打开文件数等；已有更大的值会保留；可一键恢复默认 |
| 23 | 新建 sudo 用户 | 只给 root 账号的 VPS 先建普通账号，可复制 root 的公钥、选择 sudo 是否要密码（sudoers 会先校验） |
| 24 | 常用工具 | curl、wget、vim、htop、jq、git、mtr、dig、rsync、tmux 等；可选装 Docker（用系统软件源，不运行第三方脚本） |
| 25 | 端口占用 | 列出每个端口的程序，并区分「仅本机」还是「对外」（只读） |
| 26 | 恢复备份 | 选择某一次改动整体撤销：还原改过的文件、删掉那次新建的文件、重新加载相关服务；撤销前的状态也会备份 |
| 27 | 切换软件源 | 国内机器换阿里云 / 清华 / 中科大源；更新失败会自动恢复；随时可以换回原来的源 |
| 28 | 流量超额自动关机 | 用 vnstat 统计每月流量（可选只算出站或进出合计、设账单日），到 90% 提醒，超额后自动关机或只提醒 |
| 0 | 退出脚本 | 也可以输入 q |
| u | 卸载 | 只卸载工具，或同时把所有改过的文件还原成第一次修改前的样子（装过的软件不卸载） |
| a | 一键推荐优化 | 依次执行 7、8、9、10、11、12、18、14、17、6、5、4、21；已经优化过的项目自动跳过，保留你现有的配置。SSH 加固和改端口有锁死风险，**不包含在内**，请单独执行第 2、3 项 |

建议顺序：先执行 `s` 看一眼状态，再执行 `a`（一键推荐优化），再依次执行 `1`（添加公钥）→ `2`（SSH 加固）→ `3`（改端口）。一键推荐会把时区设为 `Asia/Shanghai`，其他时区请单独执行第 12 项。

## 甲骨文云需要知道的几件事

- **两层防火墙**：网页上的「安全列表 / 网络安全组」和系统里的 iptables，两层都放行，端口才能访问。脚本只能改系统这一层，网页那层会给出操作提示。
- 系统里的规则在 `/etc/iptables/rules.v4`，末尾有一条 `REJECT`，新规则必须插在它前面，脚本会自动处理。
- **不要执行 `iptables -F`**：OUTPUT 链里的 `InstanceServices` 规则负责启动盘和元数据服务，删掉后不会自动恢复。脚本不会动这些规则。
- 默认不启用 UFW，脚本沿用甲骨文原生的 iptables 方式；如果机器已经启用了 UFW，就改用 UFW。

## 安全设计

- 每项执行前都会说明改什么，并让你确认；`DRY_RUN=1` 可以先看完整的改动内容。
- 改过的文件备份在 `/var/backups/vps-optimize/<时间>/`，目录结构与原路径相同。
- 更换 SSH 端口时会挂一个 systemd 定时器：10 分钟内没有确认就自动恢复原端口；中途任何一步失败也会立即回滚。
- 启用 UFW 时同样有兜底：5 分钟内没有确认能登录，就自动关闭 UFW。
- 每次改动都能单独撤销（第 26 项），也能在卸载时全部撤销。
- **不收集、不上报任何使用数据。**
- 不会上传任何数据。只在两种情况下联网：
  - 用 apt 安装 / 更新软件包；
  - 查一次本机公网 IP（`api.ipify.org`），用来拼出提示里的 ssh 命令。
- 全程保持当前 SSH 窗口不要关，直到新开的窗口确认能登录。

## 测试情况

- `bash -n`、`shellcheck -S warning` 通过。
- 在甲骨文云 Ubuntu 24.04 (ARM) 上做了真机测试：
  - 第 3 项：改端口失败后自动回滚、切换到新端口并关闭旧端口、再切换回来，三种情况均通过；
  - 其余各项：在已优化的机器上用预演模式跑过（含一键推荐），确认没有修改 `/etc`。
- 第 17、19、20 项在一次性的 Ubuntu 24.04 容器里实际执行，覆盖了以下情况，全部通过：
  - UFW：首次启用，以及"能登录 / 登不上"两种确认结果；
  - 没有 systemd 的环境下，5 分钟自动关闭的兜底；
  - 快捷命令：联网失败时改用本机缓存；
  - IPv4 优先：改写配置，以及重复执行时不再改动。
- v1.2 新增的第 21–28 项和卸载，也在一次性的 Ubuntu 24.04 容器里实际执行过，覆盖以下内容：
  - 换源后能正常更新，再恢复成原来的源；
  - 流量用到 90% 提醒，超额时的动作；
  - 撤销某一次改动；
  - 卸载时撤销全部改动。
- 在 UFW 机器上测试了只读查看和预演模式。
- 没有在 Debian 和 x86 机器上做过真机测试，欢迎反馈问题。

## License

MIT

---

## English

**Vernal Dawn VPS Toolbox.** An interactive, menu-driven script for hardening and tuning a fresh VPS (Ubuntu 22.04/24.04, Debian 12, with
special handling for Oracle Cloud images). Every item is independent: it explains the change, asks for
confirmation, backs up the files it touches to `/var/backups/vps-optimize/<timestamp>/`, then verifies the result.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/insffxx/vps-optimize/main/vps-optimize.sh)   # auto-sudo if needed
sudo bash vps-optimize.sh          # menu (pick several: "1 2 5 9")
sudo bash vps-optimize.sh auto     # recommended safe set, press Enter all the way
sudo bash vps-optimize.sh status   # read-only overview
sudo DRY_RUN=1 bash vps-optimize.sh  # print planned changes only
```

Items: SSH key, SSH hardening (refuses to disable passwords if no key is present), SSH port change (old and new
ports both open first, auto-rollback after 10 minutes unless confirmed), IPv6 firewall parity, fail2ban, disabling
unused services, updates, unattended security updates (no auto-reboot), BBR, sysctl hardening, swap, timezone,
hostname, journald limit, DNS over TLS (Cloudflare/Google or AliDNS/DNSPod), opening a firewall port (IPv4 + IPv6,
persisted), IPv4 preference, time sync, a minimal UFW firewall (auto-disables after 5 minutes unless you confirm you
can still log in), system cleanup, memory-aware network tuning, sudo user creation, common tools / Docker (distro
packages), port listing, per-change restore, apt mirror switching, a monthly traffic cap (vnstat), and an uninstaller
that can revert every change. After installing the shortcut, just type `ins`. No telemetry.

On Oracle Cloud, both the VCN security list and the instance's own iptables must allow a port. The script handles
the iptables side (inserting rules before the image's `REJECT` rule) and tells you what to add in the console. It
never flushes iptables or touches the `InstanceServices` chain.
