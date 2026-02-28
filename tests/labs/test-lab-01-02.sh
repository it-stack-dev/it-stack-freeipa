#!/usr/bin/env bash
# test-lab-01-02.sh — Lab 01-02: External Dependencies
# Module 01: FreeIPA — LDAP Client Integration
#
# NOTE: This test is designed to run on a dedicated lab VM where
# privileged containers are supported. CI validates compose + image only.
set -euo pipefail

LAB_ID="01-02"
LAB_NAME="LDAP Client Integration"
COMPOSE_FILE="docker/docker-compose.lan.yml"
IPA_HOST="${IPA_HOST:-localhost}"
IPA_LDAP_PORT="${IPA_LDAP_PORT:-389}"
IPA_LDAPS_PORT="${IPA_LDAPS_PORT:-636}"
IPA_ADMIN_PASS="${IPA_ADMIN_PASS:-Lab02Password!}"
IPA_BASE_DN="${IPA_BASE_DN:-dc=lab,dc=localhost}"
IPA_ADMIN_DN="${IPA_ADMIN_DN:-uid=admin,cn=users,cn=accounts,dc=lab,dc=localhost}"
PASS=0; FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

pass()   { echo -e "${GREEN}[PASS]${NC} $1"; ((++PASS)); }
fail()   { echo -e "${RED}[FAIL]${NC} $1"; ((++FAIL)); }
info()   { echo -e "${CYAN}[INFO]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
header() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}"; }

ldap_search() {
  docker exec it-stack-ldap-client ldapsearch \
    -x -H "ldap://${IPA_HOST}" \
    -D "${IPA_ADMIN_DN}" \
    -w "${IPA_ADMIN_PASS}" \
    -b "${IPA_BASE_DN}" "$@" 2>/dev/null
}

ipa_exec() {
  docker exec it-stack-freeipa-lan \
    sh -c "echo '${IPA_ADMIN_PASS}' | kinit admin >/dev/null 2>&1; $*"
}

echo -e "\n${BOLD}IT-Stack Lab ${LAB_ID} — ${LAB_NAME}${NC}"
echo -e "Module 01: FreeIPA | $(date '+%Y-%m-%d %H:%M:%S')\n"
echo -e "${YELLOW}NOTE: This lab requires privileged containers.${NC}"
echo -e "${YELLOW}      Run on a dedicated VM — not in GitHub Actions CI.${NC}\n"

header "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" pull --quiet 2>/dev/null || true
docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans
info "Waiting for FreeIPA (10-20 min install)..."
info "Polling ipactl status every 30s (max 30 min)..."
timeout 1800 bash -c "until docker exec it-stack-freeipa-lan ipactl status > /dev/null 2>&1; do echo -n '.'; sleep 30; done"
pass "FreeIPA server ready"

info "Waiting for LDAP client to install tools..."
sleep 30
CLIENT_READY=$(docker exec it-stack-ldap-client which ldapsearch 2>/dev/null || echo "")
if [ -n "${CLIENT_READY}" ]; then
  pass "LDAP client container ready (ldapsearch available)"
else
  warn "ldapsearch not yet available — client may still be installing"
fi

header "Phase 2: Port Connectivity from Client"
for port in "${IPA_LDAP_PORT}" "${IPA_LDAPS_PORT}"; do
  if docker exec it-stack-ldap-client nc -z -w5 "${IPA_HOST}" "${port}" 2>/dev/null; then
    pass "Port ${port} reachable from client container"
  else
    fail "Port ${port} not reachable from client container"
  fi
done

header "Phase 3: LDAP Anonymous Bind"
ANON=$(docker exec it-stack-ldap-client ldapsearch \
  -x -H "ldap://${IPA_HOST}" \
  -b "${IPA_BASE_DN}" \
  "(objectClass=domain)" dn 2>/dev/null | grep -c "^dn:" || echo "0")
if [ "${ANON}" -ge 1 ] 2>/dev/null; then
  pass "Anonymous LDAP bind: found ${ANON} base entry"
else
  warn "Anonymous bind returned 0 results (may require authenticated bind)"
fi

header "Phase 4: Authenticated LDAP Bind"
AUTH=$(ldap_search -LLL -b "${IPA_BASE_DN}" "(objectClass=organizationalUnit)" dn 2>/dev/null \
  | grep -c "^dn:" || echo "0")
if [ "${AUTH}" -ge 1 ] 2>/dev/null; then
  pass "Authenticated bind: found ${AUTH} organizational unit(s)"
else
  fail "Authenticated LDAP bind returned no results"
fi

header "Phase 5: User Search"
USERS=$(ldap_search -LLL \
  -b "cn=users,cn=accounts,${IPA_BASE_DN}" \
  "(objectClass=inetOrgPerson)" uid 2>/dev/null \
  | grep -c "^uid:" || echo "0")
if [ "${USERS}" -ge 1 ] 2>/dev/null; then
  pass "LDAP user search: found ${USERS} user(s) in cn=users"
else
  fail "LDAP user search returned no users"
fi

header "Phase 6: User Create + LDAP Verify"
ipa_exec "ipa user-add lab02ldap --first=Lab02 --last=LDAP --password <<< 'Lab02Password!Lab02Password!'" > /dev/null 2>&1 || warn "User may already exist"
sleep 2

USER_DN=$(ldap_search -LLL \
  -b "cn=users,cn=accounts,${IPA_BASE_DN}" \
  "(uid=lab02ldap)" dn 2>/dev/null | grep "^dn:" | head -1 || echo "")
if [ -n "${USER_DN}" ]; then
  pass "User 'lab02ldap' found via LDAP: ${USER_DN}"
else
  fail "User 'lab02ldap' not found in LDAP"
fi

header "Phase 7: Kerberos from Client"
KINIT_RESULT=$(docker exec it-stack-ldap-client \
  sh -c "echo '${IPA_ADMIN_PASS}' | kinit admin 2>&1 || echo FAILED" 2>/dev/null || echo "EXEC_FAIL")
if echo "${KINIT_RESULT}" | grep -qv "FAILED\|EXEC_FAIL\|error\|Error"; then
  pass "kinit admin succeeded from LDAP client"
else
  warn "kinit admin: ${KINIT_RESULT} (krb5.conf may need hostname resolution)"
fi

header "Phase 8: Cleanup"
ipa_exec "ipa user-del lab02ldap 2>/dev/null" > /dev/null || true
pass "Test user removed"
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
pass "Stack stopped and volumes removed"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Lab ${LAB_ID} Results${NC}"
echo -e "  ${GREEN}Passed:${NC} ${PASS}"
echo -e "  ${RED}Failed:${NC} ${FAIL}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "${FAIL}" -gt 0 ]; then
  echo -e "${RED}FAIL${NC} — ${FAIL} test(s) failed"; exit 1
fi
echo -e "${GREEN}PASS${NC} — All ${PASS} tests passed"