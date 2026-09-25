# SmartDNS App DNS

给不同应用指定不同的 SmartDNS 上游 DNS。命令会为应用创建独立的 SmartDNS group，并把清单中的域名路由到对应 group。

## 一键安装并设置

下面命令会先检查 SmartDNS。若系统尚未安装，会从 SmartDNS 官方 GitHub Release 下载适配当前系统和架构的安装包并安装；然后安装 `smartdns-app-dns`，最后把 YouTube 的上游 DNS 设为 `1.1.1.1`：

```sh
curl -fsSL https://raw.githubusercontent.com/llovely45/smartdns-app-dns/main/install.sh | sudo bash -s -- --youtube 1.1.1.1
```

一次设置多个应用：

```sh
curl -fsSL https://raw.githubusercontent.com/llovely45/smartdns-app-dns/main/install.sh | sudo bash -s -- \
  --youtube 1.1.1.1 \
  --netflix 8.8.8.8 \
  --openai 9.9.9.9
```

安装 SmartDNS 和命令，稍后再配置：

```sh
curl -fsSL https://raw.githubusercontent.com/llovely45/smartdns-app-dns/main/install.sh | sudo bash
sudo smartdns-app-dns --youtube 1.1.1.1
```

DNS 参数接受 IPv4 或 IPv6 地址。可以先用 `sudo smartdns-app-dns --list` 查看应用和域名清单。
目标系统需要 Bash 4 或更新版本。

## 安装 SmartDNS

- 如果检测到已有 SmartDNS 程序、软件包或服务，安装器会跳过 SmartDNS 安装，并使用现有配置。
- Debian/Ubuntu 优先使用 SmartDNS 官方 Release 中匹配 CPU 架构的 `.deb` 包，通过 `apt-get` 安装依赖；不会运行 `apt-get update`，也不会升级系统软件。
- 其他 Linux 发行版使用官方通用 Linux 压缩包及其自带安装脚本。当前 Release 没有适配包的系统或架构会明确报错。
- 安装包会按 GitHub Release API 提供的 SHA-256 摘要校验；校验失败时停止安装。
- 如果程序或服务已存在，但找不到 SmartDNS 配置文件，仍会停止并提示使用 `--config`；不会重复安装或猜测其他配置。
- 安装 SmartDNS 不会修改 `/etc/resolv.conf`。单独运行 `smartdns-app-dns` 命令只更新已有 SmartDNS 配置，不负责安装 SmartDNS。

## 工作方式

- 自动查找常见配置路径，并尝试从 systemd 服务、运行中的 SmartDNS 进程和 `/etc`、`/usr/local/etc`、`/opt` 下的 SmartDNS 配置文件定位实际配置。也可用 `--config /path/to/smartdns.conf` 或 `SMARTDNS_CONFIG=/path/to/smartdns.conf` 指定文件。
- 找到配置后，先创建带时间戳的 `.bak.*` 备份，再更新所选应用的域名路由；已有应用路由会切换到新 group，缺少的应用规则会自动追加。
- 修改 `/etc` 下的配置时会先尝试 `chattr -i`，写入后再执行 `chattr +i`。若现有 immutable 锁无法解开会停止；若系统没有 `chattr` 会提示无法锁定后继续。工具不会修改 `/etc/resolv.conf`。
- 每个应用使用独立的 `appdns_<应用名>` group：你指定的 DNS 是首选上游，`1.1.1.1` 作为 SmartDNS `-fallback` 备用上游。首选 DNS 无响应时，SmartDNS 重试时会使用备用 DNS；备用 DNS 不参与首次查询。若首选地址本身就是 `1.1.1.1`，只生成一次。
- 主 DNS 返回有效答复但内容不符合预期（例如 `NXDOMAIN`）时，不一定会触发回落；回落由 SmartDNS 的上游失败与重试逻辑决定。
- 默认重启 `smartdns` 服务使配置生效。可用 `--no-restart` 跳过；`--dry-run` 只显示差异，不写文件也不重启。
- 如果安装后仍没有 SmartDNS 配置文件，命令会报错并提示如何指定路径。安装器不会修改系统 `resolv.conf`。

升级后，重新运行一键安装命令并传入需要更新的应用参数，即可为这些应用写入 `1.1.1.1` 备用 DNS。例如：

```sh
curl -fsSL https://raw.githubusercontent.com/llovely45/smartdns-app-dns/main/install.sh | sudo bash -s -- --youtube 1.1.1.1 --netflix 8.8.8.8
```

## 支持的应用

| 参数 | 域名来源 |
| --- | --- |
| `--youtube` | YouTube 视频、图片和 API 域名 |
| `--tiktok` | TikTok 及其 CDN 域名 |
| `--netflix` | Netflix 播放、图片和 CDN 域名 |
| `--disney-plus` | Disney+ 相关域名 |
| `--spotify` | Spotify 相关域名 |
| `--max` | Max / HBO 相关域名 |
| `--openai` | OpenAI、ChatGPT 和 Sora 域名 |
| `--gemini` | Gemini、AI Studio 和相关 Google API 域名 |
| `--claude` | Claude / Anthropic 域名 |
| `--copilot` | Microsoft Copilot 域名 |

域名列表来自仓库根目录的 [`apps.tsv`](apps.tsv)，按应用逐行维护。

## 添加自定义应用

安装后，在 `/etc/smartdns-app-dns/apps.d/` 下创建任意 `.tsv` 文件，每行使用 `应用参数名|域名1,域名2` 格式：

```sh
sudo tee /etc/smartdns-app-dns/apps.d/custom.tsv >/dev/null <<'EOF'
myvideo|video.example.com,api.video.example.com
EOF
```

然后就可以使用新增的参数：

```sh
sudo smartdns-app-dns --myvideo 1.1.1.1
```

应用名使用小写字母开头，只包含小写字母、数字和连字符；域名需要小写。每个应用名和域名只能定义一次。自定义清单在工具更新时保留。

## 常用选项

```text
--<应用名> <IPv4|IPv6>  设置一个应用；可重复传入多个应用
--list                  列出已知应用
--config <路径>         指定 SmartDNS 配置文件
--dry-run               预览差异
--no-restart            更新后不重启服务
--help                  显示帮助
```

## 开发与发布

`apps.tsv` 是可扩展的应用/域名清单；新增内置应用时增加一行即可，参数会自动从应用名生成。修改后通过仓库的 `main` 分支即可更新一键安装脚本。

## License

MIT
