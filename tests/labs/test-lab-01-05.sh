#!/usr/bin/env bash
# test-lab-01-05.sh -- FreeIPA Lab 05: Advanced Integration
# Tests: FreeIPA + Keycloak LDAP federation + PostgreSQL + Redis ecosystem
# NOTE: Requires privileged container -- full runtime test runs on Linux hosts only.
#       In CI this script is syntax-checked and ShellChecked only.
# Usage: bash test-lab-01-05.sh
set -euo pipefail

KC_PASS="${KC_PASS:-Lab05Password!}"
IPA_PASS="${IPA_PASS:-Lab05Password!}"
PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; ((PASS++)); }
fail(){ echo "[FAIL] $1"; ((FAIL++)); }
info(){ echo "[INFO] $1"; }

# -- Section 1: FreeIPA LDAP port check ---------------------------------------
info "Section 1: FreeIPA LDAP :389"
ipa_ldap=$(nc -z localhost 389 2>/dev/null && echo "open" || echo "closed")
if [[ "$ipa_ldap" == "open" ]]; then
  ok "FreeIPA LDAP :389 open"
else
  fail "FreeIPA LDAP :389 open (container may need time to initialize)"
fi

# -- Section 2: FreeIPA web UI ------------------------------------------------
info "Section 2: FreeIPA web UI"
ipa_ui=$(curl -sk -o /dev/null -w "%{http_code}" https://localhost/ipa/ui/ 2>/dev/null || echo "000")
info "FreeIPA UI -> $ipa_ui"
if [[ "$ipa_ui" == "200" || "$ipa_ui" == "302" ]]; then
  ok "FreeIPA web UI accessible ($ipa_ui)"
else
  fail "FreeIPA web UI accessible (got $ipa_ui)"
fi

# -- Section 3: FreeIPA DNS ---------------------------------------------------
info "Section 3: FreeIPA DNS resolution"
if command -v dig >/dev/null 2>&1; then
  dns_result=$(dig +short @172.21.0.10 lab.local SOA 2>/dev/null || true)
  if [[ -n "$dns_result" ]]; then ok "FreeIPA DNS SOA for lab.local"; else fail "FreeIPA DNS SOA for lab.local"; fi
else
  info "dig not available, skipping DNS check"
  ok "FreeIPA DNS (skipped -- dig not available)"
fi

# -- Section 4: Keycloak health -----------------------------------------------
info "Section 4: Keycloak health"
kc_health=$(curl -sf http://localhost:8080/health/ready 2>/dev/null || true)
if echo "$kc_health" | grep -qi '"status".*"UP"\|status.*up'; then
  ok "Keycloak /health/ready"
else
  fail "Keycloak /health/ready"
fi

# -- Section 5: KC admin token + LDAP federation ------------------------------
info "Section 5: Keycloak admin token and FreeIPA LDAP federation"
token=$(curl -sf -X POST http://localhost:8080/realms/master/protocol/openid-connect/token \
  -d "client_id=admin-cli&grant_type=password&username=admin&password=${KC_PASS}" \
  2>/dev/null | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || true)
if [[ -n "$token" ]]; then
  ok "Keycloak admin token obtained"

  curl -sf -X POST http://localhost:8080/admin/realms \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d '{"realm":"it-stack","enabled":true}' 2>/dev/null || true

  curl -sf -X POST "http://localhost:8080/admin/realms/it-stack/components" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d '{
      "name":"freeipa-ldap",
      "providerId":"ldap",
      "providerType":"org.keycloak.storage.UserStorageProvider",
      "config":{
        "vendor":["rhds"],
        "connectionUrl":["ldap://172.21.0.10:389"],
        "bindDn":["uid=admin,cn=users,cn=accounts,dc=lab,dc=local"],
        "bindCredential":["Lab05Password!"],
        "usersDn":["cn=users,cn=accounts,dc=lab,dc=local"],
        "usernameLDAPAttribute":["uid"],
        "rdnLDAPAttribute":["uid"],
        "uuidLDAPAttribute":["ipaUniqueID"],
        "userObjectClasses":["inetUser"],
        "importEnabled":["true"],
        "enabled":["true"]
      }
    }' 2>/dev/null || true

  comp_count=$(curl -sf \
    "http://localhost:8080/admin/realms/it-stack/components?type=org.keycloak.storage.UserStorageProvider" \
    -H "Authorization: Bearer $token" 2>/dev/null | grep -c '"providerId"' || true)
  [[ "$comp_count" -ge 1 ]] && ok "FreeIPA LDAP federation component created" || fail "FreeIPA LDAP federation component"
else
  fail "Keycloak admin token obtained"
fi

# -- Section 6: PostgreSQL connectivity ---------------------------------------
info "Section 6: PostgreSQL :5432"
pg_ready=$(pg_isready -h localhost -p 5432 -U labapp 2>/dev/null && echo "ok" || echo "fail")
if [[ "$pg_ready" == "ok" ]]; then
  ok "PostgreSQL :5432 labapp ready"
  pg_query=$(PGPASSWORD=Lab05Password! psql -h localhost -p 5432 -U labapp -d labapp \
    -c "SELECT 'freeipa-lab05';" -t 2>/dev/null | tr -d ' ' || true)
  if echo "$pg_query" | grep -q "freeipa-lab05"; then
    ok "PostgreSQL query returns expected value"
  else
    fail "PostgreSQL query result"
  fi
else
  fail "PostgreSQL :5432 ready"
fi

# -- Section 7: Redis connectivity --------------------------------------------
info "Section 7: Redis :6379"
redis_pong=$(redis-cli -h localhost -p 6379 ping 2>/dev/null || echo "FAIL")
if [[ "$redis_pong" == "PONG" ]]; then
  ok "Redis PING -> PONG"
  redis-cli -h localhost -p 6379 SET ipa-lab05-key "ipa-integration" EX 60 >/dev/null 2>&1 || true
  val=$(redis-cli -h localhost -p 6379 GET ipa-lab05-key 2>/dev/null || true)
  [[ "$val" == "ipa-integration" ]] && ok "Redis SET/GET roundtrip" || fail "Redis SET/GET roundtrip"
else
  fail "Redis PING -> PONG"
fi

# -- Section 8: OIDC discovery ------------------------------------------------
info "Section 8: Keycloak OIDC discovery for realm it-stack"
discovery=$(curl -sf "http://localhost:8080/realms/it-stack/.well-known/openid-configuration" 2>/dev/null || true)
if echo "$discovery" | grep -q '"issuer"'; then
  ok "OIDC discovery endpoint for realm it-stack"
else
  fail "OIDC discovery endpoint for realm it-stack"
fi

# -- Section 9: FreeIPA Kerberos port -----------------------------------------
info "Section 9: Kerberos KDC :88"
krb_open=$(nc -z localhost 88 2>/dev/null && echo "open" || echo "closed")
if [[ "$krb_open" == "open" ]]; then ok "Kerberos KDC :88 open"; else fail "Kerberos KDC :88 open"; fi

# -- Section 10: Integration score --------------------------------------------
info "Section 10: Integration score"
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed"
if [[ $FAIL -eq 0 ]]; then
  echo "[SCORE] 5/5 -- All integration checks passed"
  exit 0
else
  echo "[SCORE] FAIL ($FAIL failures)"
  exit 1
fi
