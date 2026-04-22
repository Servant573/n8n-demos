FROM n8nio/n8n:latest
USER root
RUN find /usr/local/lib/node_modules/n8n -name 'clock.repository.js' -exec \
    sed -i 's/return now;/return now instanceof Date ? now : new Date(now);/' {} \;
USER node
