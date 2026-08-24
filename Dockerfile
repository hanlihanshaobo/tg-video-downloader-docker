# =====================================================================
# Telegram Video Downloader - Docker Image
# =====================================================================
# 本仓库【不包含源代码】，仅负责把上游项目打包成 Docker 镜像。
# 构建阶段从 UPSTREAM_REPO 克隆上游代码，再编译安装依赖。
#
# 上游项目: https://github.com/xyzbuddy/telegram-video-downloader
# 可通过 --build-arg 覆盖上游地址与分支。
#
# 多阶段构建:
#   Stage 1 (builder) : 克隆上游 + 编译依赖 (cryptg 是 C 扩展, 需要 gcc)
#   Stage 2 (runtime) : 精简镜像, 仅包含预编译 wheel + 上游脚本
# =====================================================================

# 上游源码仓库与分支（构建时可覆盖）
ARG UPSTREAM_REPO=https://github.com/xyzbuddy/telegram-video-downloader.git
ARG UPSTREAM_REF=main

# ---------- Stage 1: Builder ----------
FROM python:3.11-slim AS builder

WORKDIR /build

# 重新声明 ARG 使其在构建阶段可见
ARG UPSTREAM_REPO
ARG UPSTREAM_REF

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        gcc \
        python3-dev \
        curl \
    && rm -rf /var/lib/apt/lists/*

# 安装 Rust 工具链: cryptg>=0.5 由 Rust 重写 (setuptools-rust + PyO3)，
# 仅 x86_64/aarch64 有预编译 wheel。arm32 (arm/v7) 等平台需源码编译，
# 因此统一安装 cargo/rustc，保证任何平台都能构建。
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal \
    && /root/.cargo/bin/rustc --version
ENV PATH="/root/.cargo/bin:${PATH}"

# 克隆上游代码（默认克隆默认分支；指定 UPSTREAM_REF 时克隆对应分支）
RUN if [ -n "$UPSTREAM_REF" ]; then \
        git clone --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_REPO" src; \
    else \
        git clone --depth 1 "$UPSTREAM_REPO" src; \
    fi

# 对 downloader.py 打【去重补丁】：
#   维护 downloaded_ids.txt（与视频同目录，随数据卷持久化），
#   记录已下载的消息 ID；扫描时跳过已下载的视频，避免重复下载。
RUN python3 - <<'EOF'
path = "/build/src/downloader.py"
src = open(path, encoding="utf-8").read()

def patch(orig, new):
    global src
    n = src.count(orig)
    if n != 1:
        raise SystemExit(f"patch anchor not found (count={n}): {orig[:70]!r}")
    src = src.replace(orig, new)

# 1) 定义下载记录文件，并加载已下载的消息 ID 集合
patch(
    'downloads_dir = os.getenv("DOWNLOADS_DIR", "downloads")',
    'downloads_dir = os.getenv("DOWNLOADS_DIR", "downloads")\n'
    'downloaded_ids_file = os.path.join(downloads_dir, "downloaded_ids.txt")\n'
    'downloaded_ids = set()\n'
    'if os.path.exists(downloaded_ids_file):\n'
    '    with open(downloaded_ids_file, "r", encoding="utf-8") as _f:\n'
    '        downloaded_ids = {int(_l.strip()) for _l in _f if _l.strip()}\n'
)

# 2) 扫描时跳过已下载的消息
patch(
    '        if not message.video:\n'
    '            continue\n'
    '\n'
    '        file_size = getattr(message.file, "size", 0)',
    '        if not message.video:\n'
    '            continue\n'
    '\n'
    '        if message.id in downloaded_ids:\n'
    '            continue\n'
    '\n'
    '        file_size = getattr(message.file, "size", 0)'
)

# 3) 下载成功后把消息 ID 追加到记录文件
patch(
    '            print(f"\u2713 [Finished] Video ID: {message.id} ({video_name})")\n'
    '            return True',
    '            print(f"\u2713 [Finished] Video ID: {message.id} ({video_name})")\n'
    '            try:\n'
    '                with open(downloaded_ids_file, "a", encoding="utf-8") as _f:\n'
    '                    _f.write(f"{message.id}\\n")\n'
    '            except OSError:\n'
    '                pass\n'
    '            return True'
)

open(path, "w", encoding="utf-8").write(src)
print("dedup patch applied")
EOF

# 对 list_chats.py 打【全量会话补丁】：
#   默认脚本只列出 Channel / MegaGroup / Group，会跳过机器人和用户。
#   本补丁让 list 命令输出所有会话（含机器人、用户）及其 ID，便于查会话 ID。
RUN python3 - <<'EOF'
path = "/build/src/list_chats.py"
src = open(path, encoding="utf-8").read()

def patch(orig, new):
    global src
    n = src.count(orig)
    if n != 1:
        raise SystemExit(f"list patch anchor not found (count={n}): {orig[:70]!r}")
    src = src.replace(orig, new)

# 让所有会话类型（含 Bot / User）都打印出来，而不是 continue 跳过
patch(
    '            if isinstance(entity, Channel):\n'
    '                if entity.broadcast:\n'
    '                    chat_type = "Channel"\n'
    '                else:\n'
    '                    chat_type = "MegaGroup"\n'
    '            elif isinstance(entity, Chat):\n'
    '                chat_type = "Group"\n'
    '            else:\n'
    '                # Skip Users, Bots, and other dialog types\n'
    '                continue',
    '            if isinstance(entity, Channel):\n'
    '                if entity.broadcast:\n'
    '                    chat_type = "Channel"\n'
    '                else:\n'
    '                    chat_type = "MegaGroup"\n'
    '            elif isinstance(entity, Chat):\n'
    '                chat_type = "Group"\n'
    '            elif isinstance(entity, User):\n'
    '                chat_type = "Bot" if entity.bot else "User"\n'
    '            else:\n'
    '                chat_type = type(entity).__name__'
)

open(path, "w", encoding="utf-8").write(src)
print("list_chats patch applied")
EOF

# 编译安装依赖为 wheel（含 cryptg 等 C 扩展）
RUN pip wheel --no-cache-dir --wheel-dir /wheels -r src/requirements.txt

# ---------- Stage 2: Runtime ----------
FROM python:3.11-slim AS runtime

WORKDIR /app

# 从预编译 wheel 安装依赖（运行阶段无需编译器）
COPY --from=builder /wheels /wheels
RUN pip install --no-cache-dir /wheels/* \
    && rm -rf /wheels

# Web 后台依赖（FastAPI + uvicorn）
RUN pip install --no-cache-dir fastapi "uvicorn[standard]"

# 拷贝上游脚本与本地 entrypoint
COPY --from=builder /build/src/downloader.py /app/downloader.py
COPY --from=builder /build/src/list_chats.py /app/list_chats.py
COPY entrypoint.sh /app/entrypoint.sh
COPY webapp.py /app/webapp.py
COPY web /app/web
RUN chmod +x /app/entrypoint.sh \
    && mkdir -p /app/data

# Web 后台监听端口
EXPOSE 8080

# Python 无缓冲输出，日志即时出现在 `docker logs`
ENV PYTHONUNBUFFERED=1

# session 文件与下载的视频保存在 /app/data（挂载卷以持久化）
VOLUME ["/app/data"]

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["download"]
