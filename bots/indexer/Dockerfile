# ASK indexer. Runs anywhere that takes a Dockerfile — Railway, Fly, Render,
# Koyeb, a VPS. No platform config, no lock-in.
#
# Node 24: the indexer uses the built-in `node:sqlite`, so there is no native
# module and no build toolchain. Do not drop below 22.5 — that is where
# node:sqlite first appears, and it still warns as experimental.
FROM node:24-slim

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY schema.sql ./
COPY src ./src

# The database must live on a mounted volume. Without one, every restart
# rebuilds the whole event history from START_BLOCK — which on a real chain is
# hours of catch-up and an empty page while it runs.
ENV DB_PATH=/data/ask.db
RUN mkdir -p /data && chown -R node:node /data /app
VOLUME ["/data"]

# Most platforms inject their own PORT; the app already honours it.
ENV PORT=8747
EXPOSE 8747

USER node

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8747)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["npm", "start"]
