# =====================================================================
# Telegram Video Downloader - Docker Image
# =====================================================================
# 本仓库【内置源码】: 需要的脚本（downloader.py / list_chats.py /
# requirements.txt）直接存放在 src/，构建时不再拉取上游仓库，
# 避免上游改动导致构建失败。
#
# 多阶段构建:
#   Stage 1 (builder) : 编译依赖 (cryptg 是 C 扩展, 需要 gcc)
#   Stage 2 (runtime) : 精简镜像, 仅包含预编译 wheel + 脚本
# =====================================================================

# ---------- Stage 1: Builder ----------
FROM python:3.11-slim AS builder

WORKDIR /build

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
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

# 拷贝本仓库内置源码
COPY src/ /build/src/

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
# 注意: 不用 uvicorn[standard]，其 httptools/watchfiles 等在 arm/v7 无预编译 wheel，
#       而 runtime 阶段无编译器，会导致 arm/v7 构建失败。纯 uvicorn 完全够用。
RUN pip install --no-cache-dir fastapi uvicorn

# 拷贝内置脚本与本地 entrypoint / web 应用
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
CMD ["web"]