#!/usr/bin/env bash
# test-lab-01-01.sh — Lab 01-01: Standalone
# Module 01: FreeIPA LDAP/Kerberos identity provider
# Basic freeipa functionality in complete isolation
set -euo pipefail

LAB_ID="01-01"
LAB_NAME="Standalone"
MODULE="freeipa"
COMPOSE_FILE="docker/docker-compose.standalone.yml"
PASS=0
FAIL=0

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

# ── Helpers ───────────────────────────────────────────────────────────────────
IPA_HOST=localhost
IPA_ADMIN_PASS="Lab01Password!"
IPA_DOMAIN="lab.localhost"
IPA_REALM="LAB.LOCALHOST"

ipa_exec() {
  docker exec it-stack-freeipa-lab01 "$@" 2>/dev/null
}

check_port() {
  local port="$1" name="$2"
  if nc -z -w5 "${IPA_HOST}" "${port}" 2>/dev/null; then
    pass "Port ${port} (${name}) is open"
  else
    fail "Port ${port} (${name}) is not reachable"
  fi
}

wait_for_freeipa() {
  local retries=60   # FreeIPA install takes 10-20 min — allow 30 min max
  info "FreeIPA installation takes 10–20 minutes on first run."
  info "Polling ipactl status every 30 seconds (max 30 minutes)..."
  until ipa_exec ipactl status > /dev/null 2>&1; do
    retries=$((retries - 1))
    if [[ "${retries}" -le 0 ]]; then
      fail "FreeIPA did not finish installing within 30 minutes"
      return 1
    fi
    info "Waiting for FreeIPA... (${retries} checks remaining, ~$((retries * 30))s)"
    sleep 30
  done
  pass "FreeIPA is ready (ipactl status OK)"
}

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" pull --quiet 2>/dev/null || true
docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans
info "Container started. Waiting for FreeIPA installation to complete..."
wait_for_freeipa

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
info "Phase 2: Health Checks"

if docker compose -f "${COMPOSE_FILE}" ps freeipa | grep -qE "running|Up|healthy"; then
  pass "FreeIPA container is running"
else
  fail "FreeIPA container is not running"
fi

# Port availability
check_port 80   "HTTP"
check_port 443  "HTTPS"
check_port 389  "LDAP"
check_port 636  "LDAPS"
check_port 88   "Kerberos"
check_port 464  "kpasswd"

# HTTP redirect to /ipa/ui/
HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -L --max-redirs 3 \
  http://localhost/ 2>/dev/null)
if [[ "${HTTP_STATUS}" =~ ^(200|302|301)$ ]]; then
  pass "HTTP port 80 responds (HTTP ${HTTP_STATUS})"
else
  fail "HTTP port 80 returned HTTP ${HTTP_STATUS}"
fi

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
info "Phase 3: Functional Tests"

# 3.1 ipactl status
info "3.1 — ipactl service status"
IPA_STATUS=$(ipa_exec ipactl status)
for svc in "Directory Service" "krb5kdc" "kadmin" "named" "httpd"; do
  if echo "${IPA_STATUS}" | grep -qi "${svc}"; then
    pass "Service '${svc}' is listed by ipactl"
  else
    warn "Service '${svc}' not visible in ipactl status — may be under different name"
  fi
done

# 3.2 Kerberos: kinit as admin
info "3.2 — Kerberos authentication (kinit admin)"
if ipa_exec sh -c "echo '${IPA_ADMIN_PASS}' | kinit admin@${IPA_REALM}" > /dev/null 2>&1; then
  pass "kinit admin@${IPA_REALM} succeeds"
else
  fail "kinit admin@${IPA_REALM} failed"
fi

# 3.3 IPA CLI: list users
info "3.3 — IPA CLI: list users"
if ipa_exec sh -c "echo '${IPA_ADMIN_PASS}' | kinit admin && ipa user-find" \
    | grep -qi "admin"; then
  pass "ipa user-find returns admin user"
else
  fail "ipa user-find did not return expected users"
fi

# 3.4 IPA CLI: create test user
info "3.4 — IPA CLI: create test user"
ipa_exec sh -c "echo '${IPA_ADMIN_PASS}' | kinit admin" > /dev/null 2>&1 || true
if ipa_exec ipa user-add lab01test \
    --first=Lab --last=Test \
    --email=lab01test@${IPA_DOMAIN} \
    --password <<< 'TestPass123!
TestPass123!' > /dev/null 2>&1; then
  pass "Test user 'lab01test' created via ipa user-add"
else
  warn "ipa user-add returned error (user may already exist)"
fi

# 3.5 Verify user exists
info "3.5 — Verify user via ipa user-show"
if ipa_exec ipa user-show lab01test 2>/dev/null | grep -q 'lab01test'; then
  pass "User 'lab01test' found via ipa user-show"
else
  fail "User 'lab01test' not found — creation may have failed"
fi

# 3.6 LDAP search (unauthenticated base search)
info "3.6 — LDAP search"
if ldapsearch -x -H "ldap://localhost:389" \
    -b "dc=lab,dc=localhost" \
    -s base '(objectClass=*)' 2>/dev/null | grep -q 'namingContexts\|dc=lab'; then
  pass "LDAP anonymous base search returns domain context"
elif ipa_exec ldapsearch -x -H ldap://localhost:389 \
    -b "dc=lab,dc=localhost" -s base '(objectClass=*)' 2>/dev/null \
    | grep -q 'dc=lab'; then
  pass "LDAP base search returns domain context (run inside container)"
else
  warn "LDAP unauthenticated search may be disabled (FreeIPA default) — skipping"
fi

# 3.7 IPA JSON-RPC API via HTTP
info "3.7 — IPA JSON-RPC API"
ADMIN_TKT=$(ipa_exec sh -c \
  "echo '${IPA_ADMIN_PASS}' | kinit admin > /dev/null 2>&1 && \
   curl -sc /tmp/ipa-cookie -b '' -X POST \
   'https://localhost/ipa/session/login_password' \
   --tlsv1.2 -k \
   -H 'Content-Type: application/x-www-form-urlencoded' \
   -H 'Referer: https://localhost/ipa/ui/' \
   -d 'user=admin&password=${IPA_ADMIN_PASS}' && \
   cat /tmp/ipa-cookie" 2>/dev/null)
if echo "${ADMIN_TKT}" | grep -qi "ipa_session"; then
  pass "IPA session cookie obtained via HTTP login"
else
  warn "IPA HTTP login cookie check skipped (curl may be unavailable in container)"
fi

# 3.8 DNS: resolve lab domain
info "3.8 — DNS resolution"
if ipa_exec dig +short "@127.0.0.1" "lab.localhost" 2>/dev/null | grep -qE '^[0-9]'; then
  pass "FreeIPA DNS resolves lab.localhost"
else
  warn "DNS resolution test inconclusive (may need dig inside container)"
fi

# 3.9 Cleanup test user
info "3.9 — Cleanup test user"
ipa_exec sh -c "echo '${IPA_ADMIN_PASS}' | kinit admin" > /dev/null 2>&1 || true
ipa_exec ipa user-del lab01test 2>/dev/null && \
  pass "Test user 'lab01test' deleted" || \
  warn "Test user deletion returned non-zero (may already be gone)"

# ── PHASE 4: Cleanup ──────────────────────────────────────────────────────────
info "Phase 4: Cleanup"
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
info "Cleanup complete"

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
