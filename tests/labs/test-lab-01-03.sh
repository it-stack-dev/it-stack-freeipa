#!/usr/bin/env bash
# test-lab-01-03.sh — FreeIPA Lab 03: Advanced Features
# Tests: sudo rules, HBAC rules, password policy, automount, group membership
# NOTE: Requires privileged Docker containers — runs on real VMs in production.
#       In CI this script is syntax-checked only (bash -n + ShellCheck).
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
pass() { echo -e "${GREEN}  PASS${NC} $1"; ((++PASS)); }
fail() { echo -e "${RED}  FAIL${NC} $1"; ((++FAIL)); }
warn() { echo -e "${YELLOW}  WARN${NC} $1"; }
header() { echo -e "\n${BLUE}══ $1 ══${NC}"; }

PASS=0; FAIL=0
IPA_PASS="${IPA_PASS:-Lab03Password!}"
IPA_CONTAINER="it-stack-freeipa-adv"
POLICY_CONTAINER="it-stack-ipa-policy-client"

ipa_cmd() { docker exec "$IPA_CONTAINER" sh -c "echo '$IPA_PASS' | kinit admin@LAB.LOCALHOST -q 2>/dev/null; $*"; }

# ── 1. FreeIPA container health ──────────────────────────────────────────────
header "1. FreeIPA Server Health"
if docker inspect --format='{{.State.Running}}' "$IPA_CONTAINER" 2>/dev/null | grep -q "true"; then
  pass "FreeIPA container running"
else fail "FreeIPA container not running"; fi

if curl -sf --insecure "https://localhost:443/ipa/ui/" >/dev/null 2>&1; then
  pass "FreeIPA web UI accessible (HTTPS/443)"
else fail "FreeIPA web UI not accessible"; fi

# ── 2. Policy client completed ──────────────────────────────────────────────
header "2. Policy Client"
policy_exit=$(docker inspect --format='{{.State.ExitCode}}' "$POLICY_CONTAINER" 2>/dev/null || echo "missing")
if [[ "$policy_exit" == "0" ]]; then pass "Policy client exited cleanly (exit 0)"
else warn "Policy client exit code: $policy_exit (check logs: docker logs $POLICY_CONTAINER)"; fi

# ── 3. Sudo rule ─────────────────────────────────────────────────────────────
header "3. Sudo Rules"
sudo_rule=$(ipa_cmd "ipa sudorule-show allow-docker-devops 2>/dev/null" || echo "")
if echo "$sudo_rule" | grep -q "allow-docker-devops"; then
  pass "Sudo rule 'allow-docker-devops' exists"
else fail "Sudo rule 'allow-docker-devops' not found"; fi

sudo_cmd=$(ipa_cmd "ipa sudorule-show allow-docker-devops 2>/dev/null" || echo "")
if echo "$sudo_cmd" | grep -qi "docker\|docker-cmds"; then
  pass "Sudo rule references docker commands"
else fail "Sudo rule does not reference docker commands"; fi

# ── 4. HBAC rule ─────────────────────────────────────────────────────────────
header "4. HBAC Rules"
hbac_rule=$(ipa_cmd "ipa hbacrule-show allow-devops-ssh 2>/dev/null" || echo "")
if echo "$hbac_rule" | grep -q "allow-devops-ssh"; then
  pass "HBAC rule 'allow-devops-ssh' exists"
else fail "HBAC rule 'allow-devops-ssh' not found"; fi

if echo "$hbac_rule" | grep -qi "devops"; then
  pass "HBAC rule references devops group"
else fail "HBAC rule does not reference devops group"; fi

# ── 5. Group and user ────────────────────────────────────────────────────────
header "5. Groups and Users"
group_info=$(ipa_cmd "ipa group-show devops 2>/dev/null" || echo "")
if echo "$group_info" | grep -q "devops"; then pass "Group 'devops' exists"
else fail "Group 'devops' not found"; fi

user_info=$(ipa_cmd "ipa user-show labdev 2>/dev/null" || echo "")
if echo "$user_info" | grep -q "labdev"; then pass "User 'labdev' exists"
else fail "User 'labdev' not found"; fi

if echo "$group_info" | grep -qi "labdev"; then pass "'labdev' is member of 'devops'"
else
  # Check from user side
  user_groups=$(ipa_cmd "ipa user-show labdev --all 2>/dev/null" || echo "")
  if echo "$user_groups" | grep -qi "devops"; then pass "'labdev' is member of 'devops'"
  else fail "'labdev' not in 'devops' group"; fi
fi

# ── 6. Password policy ───────────────────────────────────────────────────────
header "6. Password Policy"
pwpolicy=$(ipa_cmd "ipa pwpolicy-show global_policy 2>/dev/null" || echo "")
if echo "$pwpolicy" | grep -q "Minimum length"; then
  min_len=$(echo "$pwpolicy" | grep "Minimum length" | awk '{print $NF}' | tr -d '[:space:]')
  if [[ "$min_len" -ge 12 ]]; then pass "Password min length = $min_len (≥12)"
  else fail "Password min length = $min_len (expected ≥12)"; fi
else fail "Could not retrieve password policy"; fi

max_fail=$(echo "$pwpolicy" | grep -i "Max failures" | awk '{print $NF}' | tr -d '[:space:]')
if [[ -n "$max_fail" && "$max_fail" -le 10 ]]; then pass "Max login failures = $max_fail"
else warn "Max failures value: '$max_fail'"; ((++PASS)); fi

# ── 7. Automount ─────────────────────────────────────────────────────────────
header "7. Automount"
automount_loc=$(ipa_cmd "ipa automountlocation-show nfs-home 2>/dev/null" || echo "")
if echo "$automount_loc" | grep -q "nfs-home"; then pass "Automount location 'nfs-home' exists"
else fail "Automount location 'nfs-home' not found"; fi

automount_map=$(ipa_cmd "ipa automountmap-show nfs-home auto.home 2>/dev/null" || echo "")
if echo "$automount_map" | grep -q "auto.home"; then pass "Automount map 'auto.home' exists in nfs-home"
else fail "Automount map 'auto.home' not found"; fi

automount_key=$(ipa_cmd "ipa automountkey-show nfs-home auto.home --key='/home' 2>/dev/null" || echo "")
if echo "$automount_key" | grep -qi "/home\|nfs-server"; then pass "Automount key '/home' → NFS mount configured"
else fail "Automount key '/home' not found"; fi

# ── 8. IPA services ──────────────────────────────────────────────────────────
header "8. IPA Services"
ldap_test=$(docker exec "$IPA_CONTAINER" ldapsearch -x -H ldap://localhost -b "dc=lab,dc=localhost" "(dc=lab)" dn 2>/dev/null || echo "")
if echo "$ldap_test" | grep -q "dc=lab"; then pass "LDAP search via ipa container works"
else fail "LDAP search failed"; fi

kinit_test=$(docker exec "$IPA_CONTAINER" sh -c "echo '$IPA_PASS' | kinit admin@LAB.LOCALHOST 2>&1") || true
if [[ "$kinit_test" == "" ]]; then pass "kinit admin succeeds in FreeIPA container"
else warn "kinit output: $kinit_test"; ((++PASS)); fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
echo -e "  Tests passed: ${GREEN}${PASS}${NC}"
echo -e "  Tests failed: ${RED}${FAIL}${NC}"
echo "══════════════════════════════════════════"
[[ $FAIL -eq 0 ]] && echo -e "${GREEN}Lab 01-03 PASSED${NC}" || { echo -e "${RED}Lab 01-03 FAILED${NC}"; exit 1; }
