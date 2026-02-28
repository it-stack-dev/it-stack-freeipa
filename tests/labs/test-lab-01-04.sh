#!/usr/bin/env bash
# test-lab-01-04.sh — FreeIPA Lab 04: Keycloak LDAP Federation with FreeIPA
# Tests: FreeIPA LDAP reachable, Keycloak federation component, user sync,
#        OIDC discovery, FreeIPA user visible in Keycloak after sync
# NOTE: Requires privileged container — full test runs on real VMs.
#       CI runs syntax check + ShellCheck only.
set -euo pipefail

PASS=0; FAIL=0
KC_PASS="${KC_PASS:-Lab04Password!}"
KC_URL="http://localhost:8080"
IPA_HOST="localhost"
REALM="it-stack"

pass()  { ((++PASS)); echo "  [PASS] $1"; }
fail()  { ((++FAIL)); echo "  [FAIL] $1"; }
warn()  { echo "  [WARN] $1"; }
header(){ echo; echo "=== $1 ==="; }

kc_token() {
  curl -sf -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli&grant_type=password&username=admin&password=${KC_PASS}" \
    | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}

header "1. FreeIPA LDAP Port Reachable"
if nc -z -w 5 "$IPA_HOST" 389 2>/dev/null; then
  pass "FreeIPA LDAP port 389 reachable"
else
  fail "FreeIPA LDAP port 389 not reachable"
fi

header "2. FreeIPA Anonymous LDAP Bind"
if ldapsearch -x -H "ldap://$IPA_HOST:389" -b "dc=lab,dc=local" "(objectClass=organizationalUnit)" dn 2>/dev/null | grep -q "numEntries"; then
  pass "Anonymous LDAP query returns OUs"
else
  warn "Anonymous bind may be disabled (normal for hardened IPA)"
fi

header "3. FreeIPA Admin LDAP Bind"
if ldapwhoami -x -H "ldap://$IPA_HOST:389" \
  -D "uid=admin,cn=users,cn=accounts,dc=lab,dc=local" \
  -w "$KC_PASS" 2>/dev/null | grep -q "dn:"; then
  pass "Admin LDAP bind successful"
else
  warn "Admin LDAP bind failed (FreeIPA may not be fully initialised)"
fi

header "4. Users OU Exists in FreeIPA"
USERS_OU=$(ldapsearch -x -H "ldap://$IPA_HOST:389" \
  -D "uid=admin,cn=users,cn=accounts,dc=lab,dc=local" -w "$KC_PASS" \
  -b "cn=users,cn=accounts,dc=lab,dc=local" "(objectClass=person)" uid 2>/dev/null | grep "uid:" | head -5)
[[ -n "$USERS_OU" ]] && pass "FreeIPA users found in cn=users,cn=accounts" || fail "Users OU empty or unreachable"

header "5. Keycloak Health"
if curl -sf "$KC_URL/health/ready" | grep -q '"status":"UP"'; then
  pass "Keycloak /health/ready UP"
else
  fail "Keycloak not ready"; exit 1
fi

header "6. Keycloak Admin Auth + Realm Setup"
TOKEN=$(kc_token)
[[ -n "$TOKEN" ]] && pass "Admin token obtained" || { fail "Admin auth failed"; exit 1; }
curl -sf -X POST "$KC_URL/admin/realms" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"realm\":\"$REALM\",\"enabled\":true}" -o /dev/null \
  && pass "Realm '$REALM' created/exists" || warn "Realm may already exist"

header "7. Create LDAP Federation Component (Keycloak → FreeIPA)"
TOKEN=$(kc_token)
LDAP_BODY="{
  \"name\": \"freeipa-ldap\",
  \"providerId\": \"ldap\",
  \"providerType\": \"org.keycloak.storage.UserStorageProvider\",
  \"config\": {
    \"vendor\": [\"rhds\"],
    \"connectionUrl\": [\"ldap://freeipa:389\"],
    \"bindDn\": [\"uid=admin,cn=users,cn=accounts,dc=lab,dc=local\"],
    \"bindCredential\": [\"$KC_PASS\"],
    \"usersDn\": [\"cn=users,cn=accounts,dc=lab,dc=local\"],
    \"usernameLDAPAttribute\": [\"uid\"],
    \"rdnLDAPAttribute\": [\"uid\"],
    \"uuidLDAPAttribute\": [\"ipaUniqueID\"],
    \"userObjectClasses\": [\"inetOrgPerson,organizationalPerson\"],
    \"editMode\": [\"READ_ONLY\"],
    \"syncRegistrations\": [\"false\"],
    \"enabled\": [\"true\"]
  }
}"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$KC_URL/admin/realms/$REALM/components" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$LDAP_BODY")
[[ "$STATUS" =~ ^(201|409)$ ]] && pass "LDAP federation component created (HTTP $STATUS)" || fail "LDAP federation failed (HTTP $STATUS)"

header "8. Trigger User Sync from FreeIPA"
TOKEN=$(kc_token)
COMP_ID=$(curl -sf "$KC_URL/admin/realms/$REALM/components?type=org.keycloak.storage.UserStorageProvider" \
  -H "Authorization: Bearer $TOKEN" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
if [[ -n "$COMP_ID" ]]; then
  SYNC=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "$KC_URL/admin/realms/$REALM/user-storage/$COMP_ID/sync?action=triggerFullSync" \
    -H "Authorization: Bearer $TOKEN")
  [[ "$SYNC" =~ ^(200|204)$ ]] && pass "Full sync triggered (HTTP $SYNC)" || warn "Sync returned HTTP $SYNC"
else
  fail "LDAP federation component not found for sync"
fi

header "9. FreeIPA Users Visible in Keycloak"
TOKEN=$(kc_token)
sleep 5  # allow sync to complete
USERS=$(curl -sf "$KC_URL/admin/realms/$REALM/users?max=50" -H "Authorization: Bearer $TOKEN")
ADMIN_USER=$(echo "$USERS" | grep -c '"username":"admin"' || true)
[[ "$ADMIN_USER" -gt 0 ]] && pass "FreeIPA admin user synced into Keycloak" || fail "FreeIPA users not synced"
TOTAL=$(echo "$USERS" | grep -o '"username"' | wc -l)
[[ "$TOTAL" -gt 0 ]] && pass "Keycloak has $TOTAL users after LDAP sync" || fail "No users after sync"

header "10. OIDC Discovery for it-stack Realm"
DISC=$(curl -sf "$KC_URL/realms/$REALM/.well-known/openid-configuration")
echo "$DISC" | grep -q '"token_endpoint"' && pass "OIDC discovery: token_endpoint present" || fail "OIDC discovery failed"
echo "$DISC" | grep -q '"authorization_endpoint"' && pass "OIDC discovery: authorization_endpoint present" || fail "Missing authorization_endpoint"

header "11. JWKS Endpoint"
JWKS_URL=$(echo "$DISC" | grep -o '"jwks_uri":"[^"]*"' | cut -d'"' -f4)
curl -sf "$JWKS_URL" | grep -q '"keys"' && pass "JWKS endpoint returns signing keys" || fail "JWKS endpoint failed"

echo
echo "═══════════════════════════════════════"
echo " Lab 01-04 Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]