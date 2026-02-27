# Dockerfile — IT-Stack FREEIPA wrapper
# Module 01 | Category: identity | Phase: 1
# Base image: freeipa/freeipa-server:rocky-9

FROM freeipa/freeipa-server:rocky-9

# Labels
LABEL org.opencontainers.image.title="it-stack-freeipa" \
      org.opencontainers.image.description="FreeIPA LDAP/Kerberos identity provider" \
      org.opencontainers.image.vendor="it-stack-dev" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/it-stack-dev/it-stack-freeipa"

# Copy custom configuration and scripts
COPY src/ /opt/it-stack/freeipa/
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
