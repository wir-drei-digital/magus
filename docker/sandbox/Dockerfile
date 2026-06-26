FROM python:3.13-slim

# Install uv (fast Python package manager)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
ENV UV_SYSTEM_PYTHON=1 UV_COMPILE_BYTECODE=1

# System packages: Node.js, build tools, LaTeX, WeasyPrint deps
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    nodejs npm curl git build-essential ripgrep \
    texlive-latex-base texlive-latex-recommended \
    texlive-fonts-recommended texlive-latex-extra \
    texlive-bibtex-extra biber \
    libpango-1.0-0 libpangoft2-1.0-0 libharfbuzz-subset0 && \
    rm -rf /var/lib/apt/lists/*

# Python packages used by skills:
#   coding:       numpy, pandas, matplotlib, requests, pillow
#   pdf:          weasyprint
#   word:         python-docx
#   spreadsheets: openpyxl
RUN uv pip install \
    numpy pandas matplotlib requests pillow \
    weasyprint python-docx openpyxl seaborn

RUN mkdir -p /workspace
WORKDIR /workspace

# File transfer server
COPY file_server.py /opt/file_server.py

EXPOSE 8080 9090

# Start file server in background (logs to /var/log), then keep container alive
CMD ["sh", "-c", "python3 /opt/file_server.py >> /var/log/file_server.log 2>&1 & sleep infinity"]
