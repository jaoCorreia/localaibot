# The brain as a cloud service (src/server.ts): bots moved here keep chatting,
# running routines and learning while the Mac is off. Data lives in
# LOCALBOT_HOME (mount a volume there); API keys go to a 0600 file in it.
FROM node:24-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY src ./src
ENV NODE_ENV=production LOCALBOT_HOME=/data LOCALBOT_SECRETS=file PORT=8080
EXPOSE 8080
CMD ["node", "--import", "tsx", "src/server.ts"]
