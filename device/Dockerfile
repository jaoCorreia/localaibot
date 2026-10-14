# A Local Bot device that runs anywhere containers do (Railway, a VPS, …):
# Cua's Linux desktop plus a small agent that serves the desktop's screen and
# hands over one authenticated HTTP port, speaking MCP.
FROM trycua/xfce-cua:latest

# Current Cua Driver for the desktop user (the image ships an older one).
USER cua
RUN curl -fsSL https://cua.ai/driver/install.sh -o /tmp/cua-driver-install.sh \
 && bash /tmp/cua-driver-install.sh --no-modify-path \
 && /home/cua/.local/bin/cua-driver telemetry disable \
 && rm /tmp/cua-driver-install.sh
USER root

COPY agent.mjs /opt/localbot/agent.mjs
COPY supervisord-localbot.conf /tmp/supervisord-localbot.conf
RUN cat /tmp/supervisord-localbot.conf >> /etc/supervisor/supervisord.conf && rm /tmp/supervisord-localbot.conf

# Railway (and most hosts) route public traffic to $PORT.
ENV PORT=8080
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=6 \
  CMD curl --fail --silent "http://127.0.0.1:${PORT}/health" >/dev/null || exit 1
