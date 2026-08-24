# Telegram Video Downloader — Docker 镜像

> **本仓库内置全部源码**（`src/`），构建时不再从上游克隆，避免上游改动导致构建失败；通过 GitHub Actions 自动构建、推送 Docker 镜像。

## 致谢（上游项目）

本镜像的核心下载/列表代码源自以下上游项目，感谢原作者的工作，已固化在本仓库 `src/` 并加以增强：

- 上游仓库：[xyzbuddy/telegram-video-downloader](https://github.com/xyzbuddy/telegram-video-downloader)
- 原功能：使用 Telethon 登录 Telegram 账号，自动下载指定频道 / 群聊中的视频文件
- 原特性：cryptg 高速解密、3 路并发下载、实时进度百分比、按大小预算筛选、`.env` 安全配置

## 功能特性

- **高速解密**：自动使用 `cryptg`（C 扩展）解密，比纯 Python 快 5–10 倍
- **并发下载**：同时最多下载 3 个视频（异步 Semaphore 控制，避免触发 Telegram 限流）
- **实时进度**：每个下载任务实时显示下载百分比
- **自动筛选**：自动识别目标频道 / 群聊中的视频消息
- **大小预算**：默认最大下载 20 GB，支持人类可读单位（`3GB` / `500MB` / `1.5MB`）
- **自动去重**：记录已下载的消息 ID（`downloaded_ids.txt`），重复运行自动跳过，不会重复下载
- **按会话分目录**：下载按会话名称保存到 `downloads/<会话名>/` 子目录
- **自动监控**：Web 后台可开启轮询，检测到会话新增视频后自动继续下载
- **中英双语**：Web 界面根据浏览器语言自动切换中/英文，也可手动切换
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
```

> 下载目标在 Web 后台或命令行中指定，无需在 `.env` 里填 `CHANNEL_ID`。

### 2. 获取镜像

**方式 A：直接拉取（推荐，CI 构建后）**

```bash
docker pull ghcr.io/hanlihanshaobo/tg-video-downloader-docker:latest
```

**方式 B：使用 docker compose**

仓库内已带 `docker-compose.yml`，`image` 已指向本项目 GHCR 镜像，直接启动即可：

```bash
docker compose up -d
```

### 3. 首次登录并列出会话

运行聊天列表工具（交互式，需输入手机号 / 验证码）：

```bash
docker compose run --rm telegram-downloader list
```

登录成功后，session 会保存在宿主机的 `./data/session.session`，之后无需重复登录。`list` 会输出**全部会话**（频道、群组、用户、机器人）及其 ID。

### 4. 使用 Web 后台

容器默认启动 **Web 后台**，浏览器访问 **http://localhost:8080**：

- 页面列出你的**全部会话**（频道、群组、机器人、用户）及对应 ID
- 点击某一行选中会话，可设置大小上限并「开始下载」
- 也可「启动自动监控」：设定轮询间隔（≥30 秒），后台定时扫描该会话，**发现新增视频自动继续下载**，直到手动停止
- 界面语言根据浏览器自动切换中/英文，右上角可手动切换
- 下载在本进程内后台执行，与查询共用同一 session（无锁冲突），进度可在 `docker compose logs -f telegram-downloader` 中查看

下载完成的视频按**会话名称**保存到 `./data/downloads/<会话名>/` 子目录，去重记录保存在 `./data/downloads/downloaded_ids.txt`（随卷持久化，删除它会重新下载全部视频）。

### 常用命令

| 命令 | 说明 |
| --- | --- |
| `docker compose up -d` | 后台启动 Web 后台（:8080） |
| `docker compose run --rm telegram-downloader list` | 列出会话（首次登录） |
| `docker compose logs -f telegram-downloader` | 跟踪下载进度 |
| `docker compose run --rm telegram-downloader download <chat_id> [dir]` | 命令行下载指定会话，可选自定义下载目录 |
| `docker compose stop` | 停止容器 |
| `docker run -it --rm --env-file .env -v "$PWD/data:/app/data" ghcr.io/hanlihanshaobo/tg-video-downloader-docker:latest list` | 纯 Docker 方式登录 |

## GitHub Actions 自动构建（CI）

仓库内置 `.github/workflows/docker-build.yml`，推送后自动完成「构建 → 推送」：

| 触发时机 | 生成的镜像标签 |
| --- | --- |
| push `main` / `master` 分支 | `latest`、`sha-<commit>` |
| push `v1.2.3` 格式的 tag | `1.2.3`、`1.2`、`1`、`latest` |
| 手动触发（Actions 页面） | `latest`、`sha-<commit>` |

- 自动构建 **linux/amd64**（x86_64）+ **linux/arm64**（aarch64）+ **linux/arm/v7**（arm32）三架构镜像（buildx + QEMU）
- 推送到 **GHCR**：`ghcr.io/hanlihanshaobo/tg-video-downloader-docker`，无需额外配置（使用内置 `GITHUB_TOKEN`）

### 使用 CI 的步骤

1. 把本仓库推送到你自己的 GitHub 仓库（或 fork 后使用）
2. 首次推送后，在 Actions 页面确认 workflow 运行成功
3. 到仓库主页 `Packages` 标签页确认 GHCR 镜像已生成（首次构建后 GHCR 会默认标记为 private，可在镜像设置中改为 public）
4. 需要发版时打 tag：`git tag v1.0.0 && git push origin v1.0.0`

## 安全提醒

- **切勿**提交 `.env`、`*.session` 文件到仓库——它们包含你的 Telegram 登录凭据
- 本仓库的 `.gitignore` 与 `.dockerignore` 已自动排除这些文件及 `data/`、`downloads/` 目录
- 会话与下载数据通过 `./data` 卷持久化，删除容器不影响数据

## 免责声明

本项目仅用于个人合法用途。请遵守目标频道的内容版权与 Telegram 服务条款，下载内容请自行负责。