#!/usr/bin/env bash

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-bot-speaker-1}"
DATABASE_ID="(default)"
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOOGLE_SERVICE_INFO="${REPOSITORY_ROOT}/macOS/BotSpeaker/GoogleService-Info.plist"

if command -v gcloud >/dev/null 2>&1; then
  GCLOUD_BIN="$(command -v gcloud)"
elif [[ -x /Users/sihaolu/Downloads/google-cloud-sdk/bin/gcloud ]]; then
  GCLOUD_BIN=/Users/sihaolu/Downloads/google-cloud-sdk/bin/gcloud
else
  echo "gcloud was not found." >&2
  exit 1
fi

API_KEY="$(/usr/libexec/PlistBuddy -c 'Print :API_KEY' "$GOOGLE_SERVICE_INFO")"
ADMIN_TOKEN="$($GCLOUD_BIN auth print-access-token)"
ROOM_ID="integration-$(uuidgen | tr '[:upper:]' '[:lower:]')"
PAIRING_CODE="$(uuidgen | tr -d '-' | cut -c1-6)"
FIRESTORE_ROOT="https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/${DATABASE_ID}/documents"
COMMIT_URL="https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/${DATABASE_ID}/documents:commit"
HOST_TOKEN=""
CLIENT_TOKEN=""
INTRUDER_TOKEN=""
HOST_UID=""
CLIENT_UID=""

auth_request() {
  local path="$1"
  local body="$2"
  curl --silent --show-error --fail \
    "https://identitytoolkit.googleapis.com/v1/${path}?key=${API_KEY}" \
    --header 'Content-Type: application/json' \
    --data-binary "$body"
}

firestore_request() {
  local token="$1"
  local method="$2"
  local url="$3"
  local body="${4:-}"
  if [[ -n "$body" ]]; then
    curl --silent --show-error --fail --request "$method" "$url" \
      --header "Authorization: Bearer ${token}" \
      --header 'Content-Type: application/json' \
      --data-binary "$body"
  else
    curl --silent --show-error --fail --request "$method" "$url" \
      --header "Authorization: Bearer ${token}"
  fi
}

cleanup() {
  set +e
  local admin_header="Authorization: Bearer ${ADMIN_TOKEN}"
  curl --silent --request DELETE "${FIRESTORE_ROOT}/orchestrationRooms/${ROOM_ID}/turns/00000/events/integration-start" --header "$admin_header" >/dev/null
  curl --silent --request DELETE "${FIRESTORE_ROOT}/orchestrationRooms/${ROOM_ID}/turns/00000" --header "$admin_header" >/dev/null
  if [[ -n "$HOST_UID" ]]; then
    curl --silent --request DELETE "${FIRESTORE_ROOT}/orchestrationRooms/${ROOM_ID}/participants/${HOST_UID}" --header "$admin_header" >/dev/null
  fi
  if [[ -n "$CLIENT_UID" ]]; then
    curl --silent --request DELETE "${FIRESTORE_ROOT}/orchestrationRooms/${ROOM_ID}/participants/${CLIENT_UID}" --header "$admin_header" >/dev/null
  fi
  curl --silent --request DELETE "${FIRESTORE_ROOT}/orchestrationPairings/${PAIRING_CODE}" --header "$admin_header" >/dev/null
  curl --silent --request DELETE "${FIRESTORE_ROOT}/orchestrationRooms/${ROOM_ID}" --header "$admin_header" >/dev/null

  for token in "$HOST_TOKEN" "$CLIENT_TOKEN" "$INTRUDER_TOKEN"; do
    if [[ -n "$token" ]]; then
      auth_request accounts:delete "$(jq -n --arg token "$token" '{idToken:$token}')" >/dev/null
    fi
  done
}
trap cleanup EXIT

HOST_AUTH="$(auth_request accounts:signUp '{"returnSecureToken":true}')"
CLIENT_AUTH="$(auth_request accounts:signUp '{"returnSecureToken":true}')"
INTRUDER_AUTH="$(auth_request accounts:signUp '{"returnSecureToken":true}')"
HOST_TOKEN="$(jq -r '.idToken' <<<"$HOST_AUTH")"
CLIENT_TOKEN="$(jq -r '.idToken' <<<"$CLIENT_AUTH")"
INTRUDER_TOKEN="$(jq -r '.idToken' <<<"$INTRUDER_AUTH")"
HOST_UID="$(jq -r '.localId' <<<"$HOST_AUTH")"
CLIENT_UID="$(jq -r '.localId' <<<"$CLIENT_AUTH")"
EXPIRES_AT="$(date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ')"

ROOM_BODY="$(jq -n \
  --arg host "$HOST_UID" \
  --arg code "$PAIRING_CODE" \
  '{fields:{hostUID:{stringValue:$host},pairingCode:{stringValue:$code},pairingOpen:{booleanValue:true},status:{stringValue:"lobby"},activeTurnIndex:{integerValue:"-1"},totalTurns:{integerValue:"0"}}}')"
firestore_request "$HOST_TOKEN" PATCH "${FIRESTORE_ROOT}/orchestrationRooms/${ROOM_ID}" "$ROOM_BODY" >/dev/null

PAIRING_BODY="$(jq -n \
  --arg room "$ROOM_ID" \
  --arg host "$HOST_UID" \
  --arg code "$PAIRING_CODE" \
  --arg expires "$EXPIRES_AT" \
  '{fields:{code:{stringValue:$code},roomID:{stringValue:$room},hostUID:{stringValue:$host},isOpen:{booleanValue:true},expiresAt:{timestampValue:$expires}}}')"
firestore_request "$HOST_TOKEN" PATCH "${FIRESTORE_ROOT}/orchestrationPairings/${PAIRING_CODE}" "$PAIRING_BODY" >/dev/null

create_participant() {
  local token="$1"
  local uid="$2"
  local name="$3"
  local document_name="projects/${PROJECT_ID}/databases/${DATABASE_ID}/documents/orchestrationRooms/${ROOM_ID}/participants/${uid}"
  local body
  body="$(jq -n \
    --arg document "$document_name" \
    --arg uid "$uid" \
    --arg room "$ROOM_ID" \
    --arg code "$PAIRING_CODE" \
    --arg name "$name" \
    '{writes:[{update:{name:$document,fields:{uid:{stringValue:$uid},roomID:{stringValue:$room},pairingCode:{stringValue:$code},displayName:{stringValue:$name},scriptTitle:{stringValue:"Integration script"},voiceName:{stringValue:"Integration voice"},segmentCount:{integerValue:"1"},preparedSegmentCount:{integerValue:"0"},preparationError:{stringValue:""},status:{stringValue:"preparing"},isConnected:{booleanValue:true}}},updateTransforms:[{fieldPath:"joinedAt",setToServerValue:"REQUEST_TIME"},{fieldPath:"lastSeenAt",setToServerValue:"REQUEST_TIME"}],currentDocument:{exists:false}}]}')"
  firestore_request "$token" POST "$COMMIT_URL" "$body" >/dev/null
}

create_participant "$HOST_TOKEN" "$HOST_UID" "Host"
create_participant "$CLIENT_TOKEN" "$CLIENT_UID" "Remote speaker"

CLIENT_PARTICIPANT="projects/${PROJECT_ID}/databases/${DATABASE_ID}/documents/orchestrationRooms/${ROOM_ID}/participants/${CLIENT_UID}"
PREPARED_BODY="$(jq -n \
  --arg document "$CLIENT_PARTICIPANT" \
  '{writes:[{update:{name:$document,fields:{preparedSegmentCount:{integerValue:"1"},preparationError:{stringValue:""},status:{stringValue:"ready"}}},updateMask:{fieldPaths:["preparedSegmentCount","preparationError","status"]},updateTransforms:[{fieldPath:"lastSeenAt",setToServerValue:"REQUEST_TIME"}],currentDocument:{exists:true}}]}')"
firestore_request "$CLIENT_TOKEN" POST "$COMMIT_URL" "$PREPARED_BODY" >/dev/null

firestore_request "$CLIENT_TOKEN" GET "${FIRESTORE_ROOT}/orchestrationRooms/${ROOM_ID}" >/dev/null

UNAUTHORIZED_STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  "${FIRESTORE_ROOT}/orchestrationRooms/${ROOM_ID}" \
  --header "Authorization: Bearer ${INTRUDER_TOKEN}")"
[[ "$UNAUTHORIZED_STATUS" == "403" ]] || {
  echo "Expected an unpaired client read to return 403, received ${UNAUTHORIZED_STATUS}." >&2
  exit 1
}

TURN_BODY="$(jq -n \
  --arg participant "$CLIENT_UID" \
  '{fields:{index:{integerValue:"0"},participantUID:{stringValue:$participant},speakerName:{stringValue:"Remote speaker"},scriptTitle:{stringValue:"Integration script"},segmentIndex:{integerValue:"0"},status:{stringValue:"assigned"}}}')"
firestore_request "$HOST_TOKEN" PATCH "${FIRESTORE_ROOT}/orchestrationRooms/${ROOM_ID}/turns/00000" "$TURN_BODY" >/dev/null

TURN_DOCUMENT="projects/${PROJECT_ID}/databases/${DATABASE_ID}/documents/orchestrationRooms/${ROOM_ID}/turns/00000"
STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
START_BODY="$(jq -n \
  --arg document "$TURN_DOCUMENT" \
  --arg started "$STARTED_AT" \
  '{writes:[{update:{name:$document,fields:{status:{stringValue:"speaking"},text:{stringValue:"Integration turn."},startedAtClient:{timestampValue:$started}}},updateMask:{fieldPaths:["status","text","startedAtClient"]},updateTransforms:[{fieldPath:"startedAtServer",setToServerValue:"REQUEST_TIME"},{fieldPath:"updatedAt",setToServerValue:"REQUEST_TIME"}],currentDocument:{exists:true}}]}')"
firestore_request "$CLIENT_TOKEN" POST "$COMMIT_URL" "$START_BODY" >/dev/null

EVENT_DOCUMENT="${TURN_DOCUMENT}/events/integration-start"
EVENT_BODY="$(jq -n \
  --arg document "$EVENT_DOCUMENT" \
  --arg participant "$CLIENT_UID" \
  --arg started "$STARTED_AT" \
  '{writes:[{update:{name:$document,fields:{type:{stringValue:"started"},participantUID:{stringValue:$participant},clientTimestamp:{timestampValue:$started}}},updateTransforms:[{fieldPath:"timestamp",setToServerValue:"REQUEST_TIME"}],currentDocument:{exists:false}}]}')"
firestore_request "$CLIENT_TOKEN" POST "$COMMIT_URL" "$EVENT_BODY" >/dev/null

# A paired participant may touch the room's activityAt poll marker (and only
# that field) so polling clients notice state changes cheaply.
ROOM_DOCUMENT="projects/${PROJECT_ID}/databases/${DATABASE_ID}/documents/orchestrationRooms/${ROOM_ID}"
BUMP_BODY="$(jq -n \
  --arg document "$ROOM_DOCUMENT" \
  '{writes:[{update:{name:$document,fields:{}},updateMask:{fieldPaths:[]},updateTransforms:[{fieldPath:"activityAt",setToServerValue:"REQUEST_TIME"}],currentDocument:{exists:true}}]}')"
firestore_request "$CLIENT_TOKEN" POST "$COMMIT_URL" "$BUMP_BODY" >/dev/null

INTRUDER_BUMP_STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' --request POST \
  "$COMMIT_URL" \
  --header "Authorization: Bearer ${INTRUDER_TOKEN}" \
  --header 'Content-Type: application/json' \
  --data-binary "$BUMP_BODY")"
[[ "$INTRUDER_BUMP_STATUS" == "403" ]] || {
  echo "Expected an unpaired activity bump to return 403, received ${INTRUDER_BUMP_STATUS}." >&2
  exit 1
}

FORBIDDEN_ROOM_UPDATE="$(jq -n '{fields:{status:{stringValue:"stopped"}}}')"
FORBIDDEN_STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' --request PATCH \
  "${FIRESTORE_ROOT}/orchestrationRooms/${ROOM_ID}?updateMask.fieldPaths=status" \
  --header "Authorization: Bearer ${CLIENT_TOKEN}" \
  --header 'Content-Type: application/json' \
  --data-binary "$FORBIDDEN_ROOM_UPDATE")"
[[ "$FORBIDDEN_STATUS" == "403" ]] || {
  echo "Expected a remote client room update to return 403, received ${FORBIDDEN_STATUS}." >&2
  exit 1
}

TURN_RESULT="$(firestore_request "$HOST_TOKEN" GET "${FIRESTORE_ROOT}/orchestrationRooms/${ROOM_ID}/turns/00000")"
jq -e '.fields.status.stringValue == "speaking" and (.fields.startedAtServer.timestampValue | length > 0)' <<<"$TURN_RESULT" >/dev/null

SKIP_BODY="$(jq -n '{fields:{status:{stringValue:"skipped"}}}')"
firestore_request "$HOST_TOKEN" PATCH \
  "${FIRESTORE_ROOT}/orchestrationRooms/${ROOM_ID}/turns/00000?updateMask.fieldPaths=status" \
  "$SKIP_BODY" >/dev/null
STALE_START_STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' --request POST \
  "$COMMIT_URL" \
  --header "Authorization: Bearer ${CLIENT_TOKEN}" \
  --header 'Content-Type: application/json' \
  --data-binary "$START_BODY")"
[[ "$STALE_START_STATUS" == "403" ]] || {
  echo "Expected a skipped turn to reject a stale speaking update, received ${STALE_START_STATUS}." >&2
  exit 1
}

echo "Orchestration backend integration test passed."
echo "Verified host authority, pairing, preparation readiness, participant access, terminal turn protection, server timestamps, activity-marker bumps, and unpaired-client denial."
