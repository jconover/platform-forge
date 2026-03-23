FROM node:20-slim AS build

WORKDIR /app

COPY package.json ./
RUN npm install --production

COPY src/ ./src/
COPY app-config.yaml ./

FROM node:20-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 build-essential && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1000 backstage
WORKDIR /app

COPY --from=build --chown=backstage:backstage /app /app

USER backstage

ENV NODE_ENV=production
EXPOSE 7007

CMD ["node", "src/index.js"]
