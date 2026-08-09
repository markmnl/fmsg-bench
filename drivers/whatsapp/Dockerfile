FROM docker.io/library/node:20-bookworm-slim

# Chromium + the shared libs puppeteer needs; whatsapp-web.js drives the
# system chromium instead of downloading its own.
RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium fonts-liberation ca-certificates dumb-init \
    && rm -rf /var/lib/apt/lists/*

ENV PUPPETEER_SKIP_DOWNLOAD=true \
    WA_CHROMIUM_PATH=/usr/bin/chromium

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev

COPY lib.js bot.js responder.js ./

ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "bot.js"]
