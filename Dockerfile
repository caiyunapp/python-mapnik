FROM python:3.14-rc-bookworm

# Build-time proxy support (affects apt/uv/etc. during docker build)
ARG http_proxy
ARG https_proxy
ARG no_proxy
ENV http_proxy=${http_proxy} \
    https_proxy=${https_proxy} \
    no_proxy=${no_proxy} \
    HTTP_PROXY=${http_proxy} \
    HTTPS_PROXY=${https_proxy} \
    NO_PROXY=${no_proxy}

# 添加 Debian sid 仓库以获取 Mapnik 4.2
RUN echo "deb http://deb.debian.org/debian sid main" >> /etc/apt/sources.list.d/sid.list && \
    echo 'Package: *\nPin: release a=sid\nPin-Priority: 100' > /etc/apt/preferences.d/sid

# 安装必要的工具
RUN apt-get update && \
    apt-get install -y \
    build-essential \
    pkg-config

# 安装 Mapnik 4.2 和必要的开发工具
RUN apt-get install -y -t sid \
    libmapnik-dev \
    fonts-noto-cjk

# 需要额外的依赖写在这里，避免缓存失效。上面的依赖安装起来时间很长
RUN apt-get install -y \
    libbz2-dev \
    && rm -rf /var/lib/apt/lists/*

# 安装 uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# 复制依赖文件
COPY pyproject.toml .
COPY uv.lock* ./

# 复制源代码文件（构建本地包所需）
COPY src/ src/
COPY setup.py .
COPY build.py .
COPY packaging/ packaging/

# 安装 Python 依赖（包括构建本地 python-mapnik）
# 使用 --verbose 显示详细的编译日志
RUN uv sync --frozen --no-dev --verbose || uv sync --no-dev --verbose
