FROM python:3.13-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends git openssh-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY pyproject.toml README.md ./
COPY huske_mcp ./huske_mcp
RUN pip install --no-cache-dir .

RUN useradd --system --home /var/lib/huske-mcp --create-home huske
USER huske

ENV HUSKE_MCP_DATA_DIR=/var/lib/huske-mcp
EXPOSE 7641
ENTRYPOINT ["huske-mcp"]
CMD ["serve"]
