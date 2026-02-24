#!/bin/bash
# keycloak/init.sh
#
# Inizializza il realm "filebrowser" con client, gruppi e utenti di test.
# Idempotente: ogni oggetto viene creato solo se non esiste già.
# Eseguito dal servizio "keycloak-init" in compose.yaml al primo avvio.
#
# Nota: UBI-minimal non ha python3/awk/jq; usa solo kcadm -F/-q e sed/grep
# (entrambi presenti in ubi9-minimal).

set -euo pipefail

KCADM=/opt/keycloak/bin/kcadm.sh
KC_URL=http://keycloak:8080
REALM=filebrowser

# Deve corrispondere a OAUTH2_PROXY_CLIENT_SECRET in compose.yaml
CLIENT_ID=oauth2-proxy
CLIENT_SECRET=dev-client-secret-filebrowser
REDIRECT_URI=http://localhost:8080/oauth2/callback

# Helper: estrae il valore del primo campo "id" dall'output JSON di kcadm
# Esempio input: [ { "id" : "abc-123" } ]
extract_id() {
  sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' | head -1
}

# ---------------------------------------------------------------------------
# Attendi che le API REST di Keycloak siano operative
# ---------------------------------------------------------------------------
echo "⏳ Attendo che le API REST di Keycloak siano pronte..."
until $KCADM config credentials \
        --server "$KC_URL" \
        --realm master \
        --user admin \
        --password admin \
        --config /tmp/kcadm.config 2>/dev/null; do
  sleep 3
done
echo "✅ Keycloak pronto."

# ---------------------------------------------------------------------------
# Realm
# ---------------------------------------------------------------------------
if $KCADM get realms/"$REALM" --config /tmp/kcadm.config &>/dev/null; then
  echo "ℹ️  Realm '$REALM' già presente, skip."
else
  echo "📦 Creo realm '$REALM'..."
  $KCADM create realms --config /tmp/kcadm.config \
    -s realm="$REALM" \
    -s enabled=true \
    -s displayName="File Browser"
fi

# ---------------------------------------------------------------------------
# Gruppo admin
# ---------------------------------------------------------------------------
ADMIN_GROUP_ID=$(
  $KCADM get groups -r "$REALM" --config /tmp/kcadm.config \
    -q name=admin -F id 2>/dev/null | extract_id
)

if [ -n "$ADMIN_GROUP_ID" ]; then
  echo "ℹ️  Gruppo 'admin' già presente (id: $ADMIN_GROUP_ID), skip."
else
  echo "👥 Creo gruppo 'admin'..."
  ADMIN_GROUP_ID=$(
    $KCADM create groups -r "$REALM" --config /tmp/kcadm.config -i \
      -s name=admin
  )
  echo "   ↪ id: $ADMIN_GROUP_ID"
fi

# ---------------------------------------------------------------------------
# Client oauth2-proxy
# ---------------------------------------------------------------------------
CLIENT_DB_ID=$(
  $KCADM get clients -r "$REALM" --config /tmp/kcadm.config \
    -q clientId="$CLIENT_ID" -F id 2>/dev/null | extract_id
)

if [ -n "$CLIENT_DB_ID" ]; then
  echo "ℹ️  Client '$CLIENT_ID' già presente (id: $CLIENT_DB_ID), skip."
else
  echo "🔑 Creo client '$CLIENT_ID'..."
  CLIENT_DB_ID=$(
    $KCADM create clients -r "$REALM" --config /tmp/kcadm.config -i \
      -s clientId="$CLIENT_ID" \
      -s enabled=true \
      -s publicClient=false \
      -s secret="$CLIENT_SECRET" \
      -s standardFlowEnabled=true \
      -s directAccessGrantsEnabled=true \
      -s "redirectUris=[\"$REDIRECT_URI\"]" \
      -s 'webOrigins=["*"]'
  )
  echo "   ↪ id: $CLIENT_DB_ID"

  echo "   ↪ Aggiungo protocol mapper 'groups' (X-Auth-Request-Groups)..."
  $KCADM create \
    "clients/${CLIENT_DB_ID}/protocol-mappers/models" \
    -r "$REALM" --config /tmp/kcadm.config \
    -s name=groups \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-group-membership-mapper \
    -s 'config."full.path"=false' \
    -s 'config."id.token.claim"=true' \
    -s 'config."access.token.claim"=true' \
    -s 'config."userinfo.token.claim"=true' \
    -s 'config."claim.name"=groups'

  # Audience mapper: aggiunge il client ID al claim "aud" del token.
  # Necessario perché oauth2-proxy verifica che aud contenga il proprio client ID.
  # Senza questo, Keycloak emette aud=["account"] di default → 500 in oauth2-proxy.
  echo "   ↪ Aggiungo audience mapper (aud: oauth2-proxy)..."
  $KCADM create \
    "clients/${CLIENT_DB_ID}/protocol-mappers/models" \
    -r "$REALM" --config /tmp/kcadm.config \
    -s name=audience \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-audience-mapper \
    -s 'config."included.client.audience"=oauth2-proxy' \
    -s 'config."id.token.claim"=false' \
    -s 'config."access.token.claim"=true'
fi

# ---------------------------------------------------------------------------
# Helper: crea utente idempotente — stampa l'id su stdout, log su stderr
# ---------------------------------------------------------------------------
create_user_if_missing() {
  local USERNAME=$1
  local PASSWORD=$2
  local EMAIL=$3

  local USER_ID
  USER_ID=$(
    $KCADM get users -r "$REALM" --config /tmp/kcadm.config \
      -q username="$USERNAME" -F id 2>/dev/null | extract_id
  )

  if [ -n "$USER_ID" ]; then
    echo "ℹ️  Utente '$USERNAME' già presente (id: $USER_ID), skip." >&2
  else
    echo "👤 Creo utente '$USERNAME'..." >&2
    USER_ID=$(
      $KCADM create users -r "$REALM" --config /tmp/kcadm.config -i \
        -s username="$USERNAME" \
        -s enabled=true \
        -s emailVerified=true \
        -s email="$EMAIL"
    )
    $KCADM set-password -r "$REALM" --config /tmp/kcadm.config \
      --username "$USERNAME" \
      --new-password "$PASSWORD"
    echo "   ↪ id: $USER_ID" >&2
  fi

  echo "$USER_ID"
}

# ---------------------------------------------------------------------------
# Utente alice — utente normale, non vede i file "secret"
# ---------------------------------------------------------------------------
create_user_if_missing alice alice alice@example.com > /dev/null

# ---------------------------------------------------------------------------
# Utente bob — admin, vede tutto
# ---------------------------------------------------------------------------
BOB_ID=$(create_user_if_missing bob bob bob@example.com)

# Aggiunge bob al gruppo admin (idempotente: Keycloak ignora se già membro)
echo "   ↪ Aggiungo 'bob' al gruppo 'admin'..."
$KCADM update \
  "users/${BOB_ID}/groups/${ADMIN_GROUP_ID}" \
  -r "$REALM" --config /tmp/kcadm.config \
  -s realm="$REALM" -n

echo ""
echo "✅ Setup Keycloak completato!"
echo "   alice (password: alice) → utente normale, i file 'secret' sono nascosti"
echo "   bob   (password: bob)   → admin, vede tutto"
