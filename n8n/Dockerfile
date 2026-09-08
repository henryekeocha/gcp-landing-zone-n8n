# Thin wrapper over the official n8n image so the landing zone owns the tag it
# deploys (pinned, scanned in Artifact Registry) instead of pulling :latest at
# runtime. Add community nodes or CA bundles here if you need them.
ARG N8N_VERSION=2.37.11
FROM docker.n8n.io/n8nio/n8n:${N8N_VERSION}

# Cloud Run sends SIGTERM and waits; n8n's own graceful shutdown handles it.
# Nothing else is customised on purpose: configuration is 100% env vars, all
# of which come from terraform/n8n (non-secret) and Secret Manager (secret).
USER node
EXPOSE 5678
