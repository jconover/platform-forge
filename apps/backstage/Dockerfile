FROM node:20-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 g++ make && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json ./
RUN npm install --production

COPY src/ ./src/
COPY app-config.yaml ./

FROM node:20-slim

WORKDIR /app

COPY --from=build --chown=node:node /app /app

USER node

ENV NODE_ENV=production
EXPOSE 7007

CMD ["node", "src/index.js"]
