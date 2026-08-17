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

# 编译安装依赖为 wheel（含 cryptg 等 C 扩展）
RUN pip wheel --no-cache-dir --wheel-dir /wheels -r src/requirements.txt

# ---------- Stage 2: Runtime ----------
FROM python:3.11-slim AS runtime

WORKDIR /app

# 从预编译 wheel 安装依赖（运行阶段无需编译器）
COPY --from=builder /wheels /wheels
RUN pip install --no-cache-dir /wheels/* \
    && rm -rf /wheels

# 拷贝上游脚本与本地 entrypoint
COPY --from=builder /build/src/downloader.py /app/downloader.py
COPY --from=builder /build/src/list_chats.py /app/list_chats.py
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh \
    && mkdir -p /app/data

# Python 无缓冲输出，日志即时出现在 `docker logs`
ENV PYTHONUNBUFFERED=1

# session 文件与下载的视频保存在 /app/data（挂载卷以持久化）
VOLUME ["/app/data"]

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["download"]
