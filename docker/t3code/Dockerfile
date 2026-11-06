# Optional T3 Code server image: t3 + git + Claude Code + Codex, running `t3 serve --lan`.
#
#   docker build -t t3code docker/t3code --build-arg T3CODE_VERSION=0.1.7
#   docker run -p 3773:3773 \
#     -e ANTHROPIC_BASE_URL=https://cliproxy.teknoir.cloud:8317 -e ANTHROPIC_AUTH_TOKEN=... \
#     -e OPENAI_BASE_URL=https://cliproxy.teknoir.cloud:8317/v1 -e OPENAI_API_KEY=... \
#     -v t3home:/home/t3/.t3 -v "$PWD":/workspace t3code
#
# Installs the published npm package (pinned by T3CODE_VERSION) rather than building the
# src/t3code fork; switch to a fork build once the fork carries its own features.

FROM node:22-bookworm-slim

ARG T3CODE_VERSION=0.1.7
ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_VERSION=latest

LABEL org.opencontainers.image.source="https://github.com/tekn0ir/t3-code" \
      org.opencontainers.image.description="T3 Code server with Claude Code and Codex" \
      org.opencontainers.image.version="${T3CODE_VERSION}"

RUN apt-get update \
 && apt-get install -y --no-install-recommends git openssh-client ca-certificates curl ripgrep tini \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g --omit=dev \
      "t3@${T3CODE_VERSION}" \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
      "@openai/codex@${CODEX_VERSION}" \
 && npm cache clean --force

# The node image already ships uid 1000 as "node"; rename it so $HOME is /home/t3.
RUN usermod -l t3 -d /home/t3 -m node && groupmod -n t3 node \
 && mkdir -p /workspace /home/t3/.t3 && chown -R t3:t3 /workspace /home/t3

USER t3
WORKDIR /workspace

ENV T3CODE_HOME=/home/t3/.t3 \
    T3CODE_PORT=3773 \
    T3CODE_NO_BROWSER=true

VOLUME ["/home/t3/.t3", "/workspace"]
EXPOSE 3773

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["t3", "serve", "--lan"]
