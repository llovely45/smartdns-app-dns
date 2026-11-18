# SmartDNS App DNS

为不同应用生成独立的 SmartDNS 上游组。内置应用默认使用测速选出的 Akile DNS，并在 SmartDNS 上配置 `1.1.1.1` 回落；命令行传入某个应用的 DNS 后，该应用改用指定地址，其他应用仍使用 Akile。

## 一键安装并应用默认规则

在 Linux VPS 上运行以下命令，会自动安装 SmartDNS（如果尚未安装）、安装本工具，并为清单中的全部应用写入默认规则：

```sh
curl -fsSL https://raw.githubusercontent.com/llovely45/smartdns-app-dns/main/install.sh | sudo bash
```

指定一个或多个应用的首选 DNS：

```sh
curl -fsSL https://raw.githubusercontent.com/llovely45/smartdns-app-dns/main/install.sh | sudo bash -s -- \
  --youtube 1.1.1.1 \
  --chatgpt 8.8.8.8 \
  --netflix 9.9.9.9
```

也可以用 `akile` 把某应用恢复为自动选择的 Akile DNS：

```sh
sudo smartdns-app-dns --youtube akile
```

只安装 SmartDNS 和本工具，不写入应用规则：

```sh
curl -fsSL https://raw.githubusercontent.com/llovely45/smartdns-app-dns/main/install.sh | sudo bash -s -- --install-only
```

查看可用应用参数和域名：

```sh
sudo smartdns-app-dns --list
```

目标系统需要 Bash 4 或更新版本。

## Akile 节点与回落方式

- 工具从 Akile 的公开 `akdns.sh` 中只读取 `DNS_LIST` 文本，不执行该脚本。安装器配置并重启 SmartDNS 后，会独立验证 `127.0.0.1:53` 是否返回有效 DNS A 记录；验证通过后才切换系统 resolver。
- 有 `dig` 时，并发测速 Akile 节点；UDP 都没有有效答复时再尝试 TCP，并按结果选择最快节点。TCP 节点会在 SmartDNS 配置中标记为 `-tcp`。
- 没有 `dig` 时使用 Akile 候选列表首个地址。Akile 脚本暂时无法读取时，使用工具内置的候选地址列表。
- `1.1.1.1 -fallback` 同时作为默认组的全局回落上游和各应用组的回落上游，因此未匹配应用规则的普通域名也可解析。SmartDNS 仅在首选上游无响应等适用情形下回落；首选上游返回有效答复（例如 `NXDOMAIN`）时，不保证触发回落。
- 不同应用共用相同地址、传输协议和回落属性的上游会合并为一条 `server` 声明，并加入相应的多个应用组，避免重复占用 SmartDNS 上游名额。写入前会检查最终配置中的上游条目数；超过 SmartDNS 的 64 条限制时拒绝更新，原配置保持不变。
- 自定义 DNS 会保存在工具生成的托管区块中；以后更新其他应用时会继续保留。指定 `--<应用名> akile` 可移除该应用的自定义覆盖。

## 安装与配置行为

- 安装器检测到 SmartDNS 未安装时，会从 SmartDNS 官方 GitHub Release 下载适配系统架构的安装包，并校验 SHA-256。已有 SmartDNS 时跳过安装。
- Debian/Ubuntu 优先安装官方 `.deb`；其他 Linux 使用官方通用 Linux 安装包。安装器不会运行 `apt-get update`，也不会升级系统软件。
- 每次运行安装器时会更新本工具和内置 `apps.tsv`。无参数运行安装器或直接运行 `smartdns-app-dns` 会应用清单中所有应用。
- 用户传入的应用 DNS 会覆盖对应应用的 Akile 默认值；已有自定义覆盖也会保留。新加入清单的应用默认使用 Akile。
- 自动定位常见 SmartDNS 配置路径，也会检查 systemd/运行进程和 `/etc`、`/usr/local/etc`、`/opt`。可用 `--config /path/to/smartdns.conf` 或 `SMARTDNS_CONFIG=/path/to/smartdns.conf` 指定配置文件。
- 检测到 `systemd-resolved` 占用 `127.0.0.53/.54:53` 时，会把主配置中的冲突通配监听自动收窄到本机 `127.0.0.1`/`::1`，并在写入前备份。现有具体网卡 IP 监听会保留；通配监听改为本机后，公网 DNS 客户端需配置具体网卡 IP 才能继续访问。由 `conf-file` 引入的配置文件需单独检查监听项。
- 写入 SmartDNS 配置前会创建带时间戳的 `.bak.*` 备份；修改 `/etc` 下的 SmartDNS 配置时先尝试 `chattr -i`，完成后再尝试 `chattr +i`。安装器完成规则写入和服务重启后，会确认 `smartdns.service` 正在运行，并通过 `dig` 直连 `127.0.0.1:53` 查询 `youtube.com`。收到有效 A 记录后，再确保服务开机自启，然后才把 `/etc/resolv.conf` 原子替换为 `nameserver 127.0.0.1`（保留原有非 nameserver 行），用 `chattr +i`/`lsattr` 锁定并确认成功，同时创建带时间戳的原文件备份。原文件若为符号链接，备份保留该符号链接，活动配置会替换为普通文件。若没有 `systemctl`/`dig`、服务未运行、查询失败、无法确认锁定或锁定失败，安装器不会保留新的 DNS 指向，并会报错；锁定失败时会尝试恢复原 resolver。
- 默认重启 SmartDNS 服务使配置生效。`--no-restart` 可跳过重启和系统 DNS 切换；`--dry-run` 只显示差异，不写文件、不重启也不切换系统 DNS。安装器参数 `--no-system-dns` 可仅跳过 `/etc/resolv.conf` 的切换，仍安装 SmartDNS 并应用规则。

如果现有 SmartDNS 已安装但没有配置文件，命令会报错并提示使用 `--config` 指定路径；它不会猜测或覆盖其他 DNS 配置文件。

## 支持的应用

参数由应用 slug 自动生成；应用域名集中维护在仓库根目录的 [`apps.tsv`](apps.tsv)。下表列出内置参数：

| 应用 | 参数 |
| --- | --- |
| Netflix | `--netflix` |
| Disney+ | `--disney-plus` |
| ChatGPT | `--chatgpt` |
| Sora | `--sora` |
| Apple AI | `--apple-ai` |
| Meta AI | `--meta-ai` |
| Spotify | `--spotify` |
| Google Search | `--google-search` |
| YouTube | `--youtube` |
| Google AI | `--google-ai` |
| Google Play | `--google-play` |
| 动画疯 | `--anime-gamer` |
| Bilibili | `--bilibili` |
| TikTok | `--tiktok` |
| Claude | `--claude` |
| HotStar | `--hotstar` |
| DAZN | `--dazn` |
| Abema TV | `--abema-tv` |
| HBO MAX | `--hbo-max` |
| KKTV | `--kktv` |
| Line TV | `--line-tv` |
| Ofiii | `--ofiii` |
| MyTVSuper | `--mytv-super` |
| Viu.TV | `--viu-tv` |
| Viu.com | `--viu-com` |
| TVBAnywhere+ | `--tvb-anywhere-plus` |
| HOY TV | `--hoy-tv` |
| Hami Video | `--hami-video` |
| CatchPlay+ | `--catchplay-plus` |
| Friday Video | `--friday-video` |
| 4GTV | `--4gtv` |
| DMM | `--dmm` |
| Hulu Japan | `--hulu-japan` |
| NicoNico | `--niconico` |
| NHK+ | `--nhk-plus` |
| U-NEXT | `--u-next` |
| TVer | `--tver` |
| D Anime Store | `--d-anime-store` |
| J:com On Demand | `--jcom-on-demand` |
| Pretty Derby Japan | `--pretty-derby-japan` |
| VideoMarket | `--video-market` |
| FOD (Fuji TV) | `--fod` |
| Radiko | `--radiko` |
| Karaoke@DAM | `--karaoke-dam` |
| Lemino | `--lemino` |
| MGStage | `--mgstage` |
| AnimeFesta | `--animefesta` |
| Telasa | `--telasa` |
| WOWOW | `--wowow` |
| Rakuten TV JP | `--rakuten-tv-jp` |
| Princess Connect Re:Dive Japan | `--princess-connect-redive-japan` |
| Project Sekai: Colorful Stage | `--project-sekai` |
| Rakuten MAGAZINE | `--rakuten-magazine` |
| Mora | `--mora` |
| music.jp | `--music-jp` |
| EroGameSpace | `--erogamespace` |
| WATCHA | `--watcha` |
| Reddit | `--reddit` |
| SD Gundam G Generation Eternal | `--sd-gundam-g-generation-eternal` |
| Wikipedia | `--wikipedia` |
| iQyi Oversea | `--iqyi-oversea` |
| Amazon Prime Video | `--amazon-prime-video` |
| Microsoft Copilot | `--microsoft-copilot` |
| MyVideo | `--myvideo` |
| Discovery+ | `--discovery-plus` |
| Paramount+ | `--paramount-plus` |

旧参数 `--openai`、`--gemini`、`--max`、`--copilot` 仍可使用，分别映射到 ChatGPT、Google AI、HBO MAX、Microsoft Copilot。

域名规则是可编辑的起始清单。个别服务可能使用新的 API/CDN 域名，可继续把域名加到 `apps.tsv` 对应行；域名不会在不同应用间重复定义。

## 添加或更新应用规则

直接修改仓库根目录的 `apps.tsv`，每行格式为 `应用参数名|域名1,域名2`。将修改推送到 `main` 后，在 VPS 上重新运行一键安装命令，安装器会更新内置清单，新增 slug 也会自动成为 `--<slug>` 参数。

也可以在 VPS 的 `/etc/smartdns-app-dns/apps.d/` 下创建本地扩展文件：

```sh
sudo tee /etc/smartdns-app-dns/apps.d/custom.tsv >/dev/null <<'EOF'
myvideo-extra|video.example.com,api.video.example.com
EOF
```

随后可运行：

```sh
sudo smartdns-app-dns --myvideo-extra 9.9.9.9
```

应用参数名以小写字母或数字开头，只能包含小写字母、数字和连字符；域名使用小写。应用名与域名不能重复定义。仓库内的应用清单更新不会覆盖本地 `apps.d` 文件。

## 常用选项

```text
--<应用名> <IPv4|IPv6>  设置该应用自定义首选 DNS
--<应用名> akile        恢复 Akile 自动 DNS
--config <路径>         指定 SmartDNS 配置文件
--list                  列出应用参数与域名
--dry-run               预览差异
--no-restart            更新后不重启服务
--help                  显示帮助
```

安装器额外选项：`--no-system-dns` 保留当前系统 DNS，不修改或锁定 `/etc/resolv.conf`。如果后续需要手动解除系统 resolver 锁，可运行 `sudo chattr -i /etc/resolv.conf`。

## License

MIT
