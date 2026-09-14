FROM mcr.microsoft.com/playwright:v1.63.0-noble@sha256:eff16c30e6f3f4af0a03fa4b706120d5e9b0891c344a27d64559aff5900a4a27

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY src ./src

ENV NODE_ENV=production \
    EMBEDPLAY_RESOLVER_HOST=0.0.0.0
USER pwuser
EXPOSE 4010
CMD ["node", "src/server.js"]
