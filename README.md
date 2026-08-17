# Telegram Video Downloader — Docker 镜像

> **本仓库不包含源代码**，仅提供基于上游项目构建的 **Docker 镜像**，并通过 GitHub Actions 自动构建、推送。
> 镜像构建时会在构建阶段从上游仓库克隆源码并编译，本地不存放任何上游代码。

## 致谢（上游项目）

本镜像的全部功能代码来自以下上游项目，感谢原作者的工作：

- 上游仓库：[xyzbuddy/telegram-video-downloader](https://github.com/xyzbuddy/telegram-video-downloader)
- 原功能：使用 Telethon 登录 Telegram 账号，自动下载指定频道 / 群聊中的视频文件
- 原特性：cryptg 高速解密、3 路并发下载、实时进度百分比、按大小预算筛选、`.env` 安全配置
- 上游代码默认从 `main` 分支拉取，可通过构建参数覆盖（见下方「本地构建」）

## 功能特性

- **高速解密**：自动使用 `cryptg`（C 扩展）解密，比纯 Python 快 5–10 倍
- **并发下载**：同时最多下载 3 个视频（异步 Semaphore 控制，避免触发 Telegram 限流）
- **实时进度**：每个下载任务实时显示下载百分比
- **自动筛选**：自动识别目标频道 / 群聊中的视频消息
- **大小预算**：默认最大下载 20 GB，超出即停止扫描
- **安全配置**：凭据与 session 通过环境变量 / 挂载卷隔离，不写入镜像

## 快速开始

### 1. 配置环境变量

```bash
cp .env.example .env
```

填入你的 Telegram 凭据（[my.telegram.org](https://my.telegram.org) 申请）：

```ini
API_ID=your_api_id_here
API_HASH=your_api_hash_here
CHANNEL_ID=your_channel_id_here
```

### 2. 获取镜像

**方式 A：直接拉取（推荐，CI 构建后）**

```bash
docker pull ghcr.io/<你的 GitHub 用户名>/telegram-video-downloader:latest
```

**方式 B：使用 docker compose**

仓库内已带 `docker-compose.yml`（请先把其中的镜像地址改成你自己的 GitHub 用户名，或改用本地构建）：

```bash
docker compose build   # 本地构建
docker compose up -d
```

### 3. 首次登录并列出频道

运行聊天列表工具（交互式，需输入手机号 / 验证码）：

```bash
docker compose run --rm telegram-downloader list
```

登录成功后，session 会保存在宿主机的 `./data/session.session`，之后无需重复登录。从输出中复制目标频道 ID（通常以 `-100` 开头），填入 `.env` 的 `CHANNEL_ID`。

### 4. 开始下载

```bash
docker compose up -d
docker compose logs -f telegram-downloader   # 实时查看进度
```

下载完成的视频保存在宿主机的 `./data/downloads/` 目录。

### 常用命令

| 命令 | 说明 |
| --- | --- |
| `docker compose up -d --build` | 构建并后台启动 |
| `docker compose run --rm telegram-downloader list` | 列出频道（首次登录） |
| `docker compose logs -f telegram-downloader` | 跟踪下载进度 |
| `docker compose stop` | 停止容器 |
| `docker run -it --rm --env-file .env -v "$PWD/data:/app/data" ghcr.io/<用户名>/telegram-video-downloader:latest list` | 纯 Docker 方式登录 |

## GitHub Actions 自动构建（CI）

仓库内置 `.github/workflows/docker-build.yml`，推送后自动完成「构建 → 推送」：

| 触发时机 | 生成的镜像标签 |
| --- | --- |
| push `main` / `master` 分支 | `latest`、`sha-<commit>` |
| push `v1.2.3` 格式的 tag | `1.2.3`、`1.2`、`1`、`latest` |
| 手动触发（Actions 页面） | `latest`、`sha-<commit>` |

- 自动构建 **linux/amd64** + **linux/arm64** 双架构镜像（buildx + QEMU）
- 默认推送到 **GHCR**：`ghcr.io/<owner>/<repo>`，无需额外配置
- **可选推送到 Docker Hub**：在仓库 `Settings → Secrets and variables → Actions` 中配置 `DOCKERHUB_USERNAME`（Variables）与 `DOCKERHUB_TOKEN`（Secrets，在 Docker Hub 创建 Read & Write 权限的 Access Token）后自动启用

### 使用 CI 的步骤

1. 把本仓库推送到你自己的 GitHub 仓库（或 fork 后使用）
2. 首次推送后，在 Actions 页面确认 workflow 运行成功
3. 到仓库主页 `Packages` 标签页确认 GHCR 镜像已生成（首次构建后 GHCR 会默认标记为 private，可在镜像设置中改为 public）
4. 需要发版时打 tag：`git tag v1.0.0 && git push origin v1.0.0`

## 本地构建

```bash
docker build -t telegram-video-downloader .
```

默认从上游 `main` 分支拉取代码。如需指定上游仓库 / 分支：

```bash
docker build \
  --build-arg UPSTREAM_REPO=https://github.com/xyzbuddy/telegram-video-downloader.git \
  --build-arg UPSTREAM_REF=main \
  -t telegram-video-downloader .
```

## 安全提醒

- **切勿**提交 `.env`、`*.session` 文件到仓库——它们包含你的 Telegram 登录凭据
- 本仓库的 `.gitignore` 与 `.dockerignore` 已自动排除这些文件及 `data/`、`downloads/` 目录
- 会话与下载数据通过 `./data` 卷持久化，删除容器不影响数据

## 免责声明

本项目仅用于个人合法用途。请遵守目标频道的内容版权与 Telegram 服务条款，下载内容请自行负责。
