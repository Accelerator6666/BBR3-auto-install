# BBR3-auto-install

**一条命令安装 BBRv3，自动识别系统版本与 CPU 架构，自动验证、安排安全试启动，并在首次启动成功后持久化。**

> **v0.2.1：自动识别系统/架构，并按 RAM 分档配置 Swap。** 安装器读取 `/etc/os-release` 识别发行版和版本，并交叉核对 `uname -m` 与 `dpkg --print-architecture`，自动选择 x86_64/AMD64 或 ARM64/AArch64 对应的固定 Release 与 SHA256。识别/包映射范围为 **Debian 12+、Ubuntu 24.04+、x86_64、ARM64**。当前引导安装仍限定 **BIOS + GRUB + systemd**；UEFI、Secure Boot、LXC/Docker、RPM/APK 系统不支持。完整端到端安装目前仅有此前 AWS EC2 Debian 12 amd64 手工验证，Ubuntu、ARM64 和 Debian 13 仍需测试实例回归，不应直接用于生产。

本项目为独立的安装/验证编排程序，**不编译内核**；所使用的 BBRv3 内核由第三方项目 [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3) 发布。安装的内核包包含第三方可执行内核代码及 DEB 维护脚本，请先评估上游供应链风险。

## 一键安装

**先在云平台创建可恢复的系统盘快照/AMI，并确认 Serial Console 或救援挂载可用。** 安装器无法通过本机判断云快照是否已完成，需要你明确确认。安装会修改 GRUB、sysctl，并在成功准备后重启服务器，因此会短暂中断 SSH 和运行中的业务。

```bash
curl -fsSL https://raw.githubusercontent.com/Accelerator6666/BBR3-auto-install/main/install.sh -o /tmp/bbr3-install.sh && \
sudo bash /tmp/bbr3-install.sh --yes --backup-confirmed
```

推荐先查看脚本源码后运行；**不要直接执行未经审阅的 `curl | bash`**。以上命令在完成准备阶段后会自动重启一次，旧内核为正常默认，新内核为仅一次的试启动。首次启动后由 systemd 自检，检查通过才设置 BBRv3 为默认内核。

**只准备、不立即重启：**

```bash
sudo bash /tmp/bbr3-install.sh --yes --backup-confirmed --no-reboot
```

**查看运行状态：**

```bash
sudo bash /tmp/bbr3-install.sh --status
uname -r
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
tc -s qdisc show
sudo grub-editenv list
sudo systemctl status bbr3-finalize.service --no-pager
```

## 安装器做什么

1. 自动检测发行版、版本、CPU 架构，并校验系统架构与 DEB 包架构一致；当前允许 Debian 12+ / Ubuntu 24.04+、x86_64 / ARM64。随后检测 BIOS + GRUB、systemd、当前内核回退镜像、可用磁盘、dpkg 和 IPv4 默认路由；拒绝 UEFI、容器及其他未经验证的启动组合。
2. 自动读取 `/proc/meminfo` 的 RAM 和当前已启用 Swap，按总 Swap 目标分档：RAM <1 GiB → 2 GiB；1–2 GiB → 1 GiB；2–4 GiB → 512 MiB；RAM ≥4 GiB 不主动改动 Swap。已有 Swap（包括 zram）计入总量，只补足差额，不关闭或调整现有 Swap。
3. 备份 GRUB 配置和旧内核启动文件；**在安装内核包之前**设置旧内核为默认启动项。
4. 从固定的第三方 Release 下载并校验 Image / Headers 的 **固定 SHA256**；验证包名、版本、内核配置及 AWS ENA 驱动。
3. Swap 文件采用 `/swapfile-bbr3`（若已被占用则选择带序号的新路径），权限设为 `0600`，优先使用 `fallocate`，失败时回退到 `dd`；写入 `/etc/fstab` 的 `nofail` 持久化条目，并在失败时回滚新增条目。原始 fstab 会先备份。创建前检查剩余磁盘空间，必须额外保留 Swap 文件大小 + 3 GiB 安装空间 + 512 MiB 余量；空间不足时安全终止。
5. 使用 `dpkg -i` 安装新内核并生成 initramfs；检查文件、dpkg 状态和 ENA 模块是否正确放入 initramfs。
6. 写入 `99-bbrv3.conf`（`bbr` + `fq`）。旧内核运行时仅写文件，不提前切换旧内核的拥塞控制。
7. 设置 GRUB `saved_entry=旧内核` 和 `next_entry=新内核`，安装 `bbr3-finalize.service`，随后自动重启（除非指定 `--no-reboot`）。
8. 新内核启动后检查 BBR、FQ、默认路由、根文件系统、AWS ENA（如适用）；**全部成功才把新内核保存为永久默认**。验证失败时旧内核仍是下一次正常启动的默认选择。

> **回退边界**：GRUB 一次性启动并不提供硬件级自动重启。如果新内核卡在启动阶段、无法联网或 systemd 没有启动，可能需要使用云控制台/Serial Console **手动触发一次重启**以回到旧内核；如果连 GRUB/磁盘也损坏，则使用预先创建的快照恢复。自检检查本机网络状态，不等价于外部端到端 SSH/性能验证。系统更新或其他 GRUB 工具以后仍可能修改默认菜单。

## 固定上游版本（v0.2）

当前固定 Linux 7.3.4 标准 BBRv3，不自动追随最新 Release。根据运行时架构选择对应资产：

| 架构 | Release Tag | Image SHA256 | Headers SHA256 |
|---|---|---|---|
| x86_64 / AMD64 | [`x86_64-7.3.4`](https://github.com/byJoey/Actions-bbr-v3/releases/tag/x86_64-7.3.4) | `0791ee3782ce935a3f984d38484a0d74b9651184390cb4bf71cccf28a07f903f` | `603a9d1f2dfacac6caa9cfee5a0f938604e93cd217148a35132c151ea0bb69e7` |
| ARM64 / AArch64 | [`arm64-7.3.4`](https://github.com/byJoey/Actions-bbr-v3/releases/tag/arm64-7.3.4) | `0ef3e4bc20726998b007a9574cead3854b9825948139bf54146e0ac4ef738317` | `4cd8fe06a7a48812f5d4e904c4ea7279c1f22f71863ac6a3764de75a4b8d26df` |

两种架构共用内核 release version `7.3.4-joeyblog-bbrv3`，但下载包和 SHA256 不同。脚本在下载前根据 `uname -m` + `dpkg --print-architecture` 选择资产，包架构不匹配会终止。

固定版本而非自动选择最新 Release，是为了避免未经验证的内核升级意外改变启动行为。支持新版本需要同时更新两种架构的 Pin、HASH 并完成测试。

## 排查与恢复

```bash
sudo cat /var/lib/bbr3-auto-install/result 2>/dev/null || true
sudo cat /var/log/bbr3-auto-install.log
sudo journalctl -u bbr3-finalize.service -b --no-pager
sudo grub-editenv list
```

安装后原内核依然保留。若机器仍可 SSH 且需要恢复旧内核，使用原备份记录的内核版本，根据当前 GRUB `Advanced options` 菜单 ID 操作；**不要假设菜单数字索引固定不变**。在无法登录时使用云控制台、串口控制台或从快照恢复。

自动安装成功不等于 BBRv3 一定比其他拥塞控制算法更快。建议在相同环境中用 `iperf3`、RTT 和 TCP 重传量对照测试。

## 项目文件

- [`install.sh`](install.sh)：单文件入口（包括嵌入的 post-boot 完成器）。
- [`tests/static-test.sh`](tests/static-test.sh)：基础 Shell 语法和静态安全检查。
- [`.github/workflows/check.yml`](.github/workflows/check.yml)：每次 PR / push 执行检查。

## 后续路线

下一阶段重点是完成 Debian 13、Ubuntu 24.04+、ARM64 的真实虚拟机/云主机端到端测试，再评估 UEFI（Secure Boot 必须解决签名问题）、其他云平台启动驱动检测、自动快照确认、发布签名和更完整的回滚策略。

## 安全与责任

- 仅用于你有管理权限的服务器。
- 第三方内核包由上游维护，不是 Debian 官方内核；项目不对上游可执行代码作安全担保。
- v0.2.0 不会安装或重写 GRUB 引导扇区，也不会卸载原内核；但会修改 GRUB 配置、sysctl 和 systemd 服务。
- 自动重启会中断当前会话及业务，生产环境应安排维护窗口。
