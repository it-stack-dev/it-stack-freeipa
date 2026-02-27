# Architecture — IT-Stack FREEIPA

## Overview

FreeIPA provides centralized identity management using LDAP, Kerberos, DNS, and PKI for the IT-Stack platform.

## Role in IT-Stack

- **Category:** identity
- **Phase:** 1
- **Server:** lab-id1 (10.0.50.11)
- **Ports:** 389 (LDAP), 636 (LDAPS), 88 (Kerberos), 53 (DNS)

## Dependencies

| Dependency | Type | Required For |
|-----------|------|--------------|
| FreeIPA | Identity | User directory |
| Keycloak | SSO | Authentication |
| PostgreSQL | Database | Data persistence |
| Redis | Cache | Sessions/queues |
| Traefik | Proxy | HTTPS routing |

## Data Flow

```
User → Traefik (HTTPS) → freeipa → PostgreSQL (data)
                       ↗ Keycloak (auth)
                       ↗ Redis (sessions)
```

## Security

- All traffic over TLS via Traefik
- Authentication delegated to Keycloak OIDC
- Database credentials via Ansible Vault
- Logs shipped to Graylog
