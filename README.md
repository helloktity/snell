<div align="center">

# Snell 一键脚本 & Docker 镜像

[![Stars](https://img.shields.io/github/stars/helloktity/snell?style=flat-square&logo=github&color=blue)](https://github.com/helloktity/snell/stargazers)
[![Forks](https://img.shields.io/github/forks/helloktity/snell?style=flat-square&logo=github&color=blue)](https://github.com/helloktity/snell/network/members)
[![Pull Requests](https://img.shields.io/github/issues-pr/helloktity/snell?style=flat-square&logo=github&color=blue)](https://github.com/helloktity/snell/pulls)
[![License](https://img.shields.io/github/license/helloktity/snell?style=flat-square&color=blue)](LICENSE)

一键安装与管理 Snell v4 / v5 / v6，支持 ShadowTLS v3、多用户与 BBR，
并提供**内置订阅服务**（输出订阅链接，Sub-Store 可用 `remote` 方式订阅本机）。

[中文](README.md) ｜ [English](README.en.md) ｜ [上游文档（Wiki）](https://github.com/jinqians/snell/wiki)

> 本仓库是 [jinqians/snell](https://github.com/jinqians/snell) 的 fork：安装管理逻辑同源，
> 主要差异是**增加了订阅服务**、脚本内置地址指向本仓库（不再回上游拉取）。

</div>

---

## 一键脚本

自动识别系统（Debian / Ubuntu / CentOS / RHEL / Alpine），直接跑对应文件即可：

| 系统 | 命令 |
|------|------|
| Debian / Ubuntu / CentOS / RHEL / Rocky / AlmaLinux | `bash <(curl -fsSL https://raw.githubusercontent.com/helloktity/snell/main/snell.sh)` |
| Alpine 3.18 及以下（原生安装） | `sh -c "$(curl -fsSL https://raw.githubusercontent.com/helloktity/snell/main/snell-alpine.sh)"` |
| Alpine（Docker 方案，3.19 起用这个） | `sh -c "$(curl -fsSL https://raw.githubusercontent.com/helloktity/snell/main/scripts/snell-docker.sh)"` |
| 多功能菜单（Snell / SS-2022 / ShadowTLS） | `bash <(curl -fsSL https://raw.githubusercontent.com/helloktity/snell/main/scripts/menu.sh)` |

装好后输入 `snell` 进入管理菜单：查看配置、修改端口 / PSK / DNS、多用户、版本管理（v4 / v5 / v6 同机共存）、ShadowTLS、BBR、规则分流、**订阅**。

`snell` 命令每次运行都会从本仓库取最新脚本，所以改了代码推送后就生效，不用重新安装。

---

## 订阅（本 fork 新增）

脚本自带一个订阅服务：把本机的 Snell 用户（含 ShadowTLS）按订阅链接输出，
Sub-Store 可以像订阅 3x-ui 那样用 `source=remote` 订阅本机，Mihomo / Surge 也能直接导入。

安装时自动启用；随时可在主菜单「14. 订阅」或命令行管理：

| 用途 | 地址（`<base>` = `http://127.0.0.1:13357/<token>`） |
|---|---|
| Sub-Store remote 源 / Clash 片段（默认） | `<base>/sub?target=clash` |
| 完整 Clash 配置（直接导入 Verge / Mihomo） | `<base>/sub?target=clash-full` |
| Surge（含 v6 与 ShadowTLS 节点） | `<base>/sub?target=surge` |
| base64 / JSON / 存活探测 | `<base>/sub?target=base64`、`<base>/sub?target=json`、`<base>/health` |

要点：

- **Clash 目标只出 Mihomo 能用的节点**（snell `version` 4 / 5）。v6 与 ShadowTLS 会被跳过，
  并在响应开头用注释写明跳过了哪个、为什么——因为塞进去会让整个 profile 无效。
  Surge 目标不过滤，v4 / v5 / v6 与 ShadowTLS 全都出。
- 服务每次请求都重读 `/etc/snell/users/*.conf` 与 ShadowTLS 的 unit，
  **加用户、改 PSK、切版本立刻生效**，不用重启订阅服务。
- 配置在 `/etc/snell/.subscription`（600），40 位 token 写在路径里；
  链接等同凭据，泄露后 `snell sub token` 重置。
- 默认只监听 `127.0.0.1`（同机 Sub-Store 够用）。要给外网用：`snell sub public`
  直接开公网监听，或保持仅本机 + `snell sub nginx` 拿到反代片段。
- 实现是纯 python3 标准库的 HTTP 服务，不需要 pip；没有 python3 时只跳过订阅，不影响 Snell 本体。

```bash
snell sub                # 查看订阅链接
snell sub on | off       # 启用 / 停用
snell sub restart        # 重启
snell sub status         # 状态
snell sub check          # 自检：逐个目标请求一次本机端点
snell sub store          # Sub-Store 里怎么填
snell sub nginx          # nginx 反代片段
snell sub token          # 重置 token
snell sub port | server  # 改订阅端口 / 节点地址
snell sub public | local # 公网监听 / 仅本机
```

Sub-Store 里新增订阅源：类型选 `remote`，URL 填 `<base>/sub?target=clash`。
**不要**再往这个源里填内容（content）——remote 源如果残留旧内容，Sub-Store 会优先用内容里的旧 PSK，
表现为「订阅是新的、输出是旧的」。

---

## Docker

镜像 [`jinqians/snell-server`](https://hub.docker.com/r/jinqians/snell-server) 由上游维护
（amd64 / arm64 / armv7；v6 没有 armv7）。容器以 `nobody` 运行，先建好配置目录：

```bash
mkdir -p ./snell-config && chown -R 65534:65533 ./snell-config
docker run -d --name snell-server --restart unless-stopped \
  -p 6160:6160/tcp -p 6160:6160/udp \
  -e SNELL_VER=v5 -e SNELL_PORT=6160 \
  -v ./snell-config:/etc/snell \
  jinqians/snell-server:v5
```

docker compose（`compose.yml`）：

```yaml
services:
  snell:
    image: jinqians/snell-server:v5
    container_name: snell-server
    restart: unless-stopped
    ports:
      - "6160:6160/tcp"
      - "6160:6160/udp"
    environment:
      - SNELL_VER=v5
      - SNELL_PORT=6160
    volumes:
      - ./snell-config:/etc/snell
```

装 Snell v6：镜像用 `:v6`、`SNELL_VER=v6`，并用 `SNELL_MODE` 选加密模式（客户端必须一致）。
ShadowTLS、切换版本、全部环境变量 → [上游文档](https://github.com/jinqians/snell/wiki/Docker-%E9%83%A8%E7%BD%B2)

> 想发布自己的镜像：`.github/workflows/docker-publish.yml` 里的 `IMAGE_NAME` 用的是
> `github.repository_owner`，fork 之后自动变成 `<你的用户名>/snell-server`，配上 Docker Hub 凭据即可。

---

## 获取客户端配置

```bash
snell                          # 菜单选「3. 查看配置」（顺带会显示订阅链接）
snell sub                      # 只要订阅链接
docker logs snell-server       # Docker：首次启动时打印在日志里，也保存在 ./snell-config/client-config.txt
```

得到的是 Surge 格式，直接粘贴：

```text
HK = snell, 1.2.3.4, 6160, psk = your_psk, version = 5, reuse = true, tfo = true
```

---

## ShadowTLS（可选）

给 Snell 套一层 TLS 伪装，对外只暴露 ShadowTLS 端口。脚本安装：菜单选「9. ShadowTLS」；
Docker：加 `SHADOWTLS_ENABLE=1` 等环境变量 → [上游文档](https://github.com/jinqians/snell/wiki/Docker-%E9%83%A8%E7%BD%B2#2-snell--shadowtls-v3)

ShadowTLS 的节点在订阅里也会出现（`target=surge`，带 `shadow-tls-password` / `shadow-tls-sni` /
`shadow-tls-version = 3`）；Clash 目标不会包含它——Mihomo 的 snell 出站没有 shadow-tls 插件。

---

## 文档

功能、用法和原理在上游 Wiki（本 fork 代码同源，文档直接通用）：

- [项目介绍](https://github.com/jinqians/snell/wiki/%E9%A1%B9%E7%9B%AE%E4%BB%8B%E7%BB%8D) —— 功能一览、仓库结构
- [脚本安装与管理](https://github.com/jinqians/snell/wiki/%E8%84%9A%E6%9C%AC%E5%AE%89%E8%A3%85%E4%B8%8E%E7%AE%A1%E7%90%86) —— 多功能菜单、v4 / v5 / v6 同机共存、Alpine
- [规则分流](https://github.com/jinqians/snell/wiki/%E8%A7%84%E5%88%99%E5%88%86%E6%B5%81) —— 用 sing-box 按规则集分流
- [Docker 部署](https://github.com/jinqians/snell/wiki/Docker-%E9%83%A8%E7%BD%B2) —— 镜像标签、ShadowTLS、v6、环境变量
- [协议介绍](https://github.com/jinqians/snell/wiki/%E5%8D%8F%E8%AE%AE%E4%BB%8B%E7%BB%8D) —— v4 / v5 / v6 对比、v6 参数选择、ShadowTLS

---

## 仓库结构

```
src/            源码（改这里）
  snell.sh        主脚本：安装 / 菜单 / 配置 / 订阅入口
  lib/*.sh        公共库：common / release / netinfo / firewall / channels / conf /
                  routing / subscription（订阅服务，v6.4 新增）
snell.sh        由 tools/build.sh 从 src/ 生成，勿直接改
snell-alpine.sh 同上（Alpine 原生安装）
scripts/*.sh    同上：menu / multi-user / shadowtls / bbr / snell-docker / install
tools/build.sh  把 src/ 与 src/lib 合成单文件；--check 校验生成文件是否最新
```

改代码的流程：

```bash
vim src/snell.sh            # 或 src/lib/*.sh
bash tools/build.sh         # 生成根目录与 scripts/ 下的发布文件
bash tools/build.sh --check # 确认没有遗漏
```

CI（`.github/workflows/scripts.yml`）会检查生成文件是否最新、`bash -n`、POSIX 脚本能否
被 dash / busybox ash 解析、shellcheck 有无 error。

---

## 相关链接

- 上游仓库：[jinqians/snell](https://github.com/jinqians/snell)（本项目 fork 自它，感谢原作者）
- Snell 协议与官方发布：[kb.nssurge.com](https://kb.nssurge.com/surge-knowledge-base/release-notes/snell)
- [Sub-Store](https://github.com/sub-store-rs/sub-store) —— 订阅管理，可用 `remote` 模式订阅本脚本
- 开源协议：[GPL-3.0](LICENSE)
