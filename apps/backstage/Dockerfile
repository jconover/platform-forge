FROM node:20-slim AS build

WORKDIR /app

COPY package.json ./
RUN npm install --production

COPY src/ ./src/
COPY app-config.yaml ./

FROM node:20-slim

RUN addgroup --system --gid 1000 backstage && \
    adduser --system --uid 1000 --ingroup backstage backstage

WORKDIR /app

COPY --from=build --chown=backstage:backstage /app /app

USER backstage

ENV NODE_ENV=production
EXPOSE 7007

CMD ["node", "src/index.js"]
