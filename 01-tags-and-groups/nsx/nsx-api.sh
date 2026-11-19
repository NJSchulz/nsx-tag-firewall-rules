#!/usr/bin/env bash
# NSX Policy API calls for the tagdemo groups and the tagdemo-3tier policy.
#
# Lab / demo only. apply-* and delete send real writes. The script only
# touches tagdemo-web, tagdemo-app, tagdemo-db, and tagdemo-3tier under
# the VPC you name, plus read-only GETs used to find ports and the Avi
# data-NIC group.
#
# Credentials come from the environment or a prompt. The password is
# written to a mode-600 curl config file and removed on exit. It is not
# placed on the curl command line.
#
#   export NSX_MANAGER=<nsx-manager>    # host or https URL
#   export NSX_USER=<api-user>          # NSX local user, Security Engineer
#   export VPC_ID=<vpc-id>
#   # optional: NSX_PASSWORD (if unset, the script prompts)
#   # apply-policy also needs AVI_SE_DATANICS_GROUP_ID
#
# -k is here because the lab manager certificate is self-signed.
# Org and project are default, matching the post.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NSX_HOST=""
NSX=""
V=""
CURL_CFG=""
RENDERED=""

usage() {
  cat <<'EOF'
Usage: nsx-api.sh <subcommand>

Environment:
  NSX_MANAGER                 NSX Manager host or https URL
  NSX_USER                    NSX local user (password is prompted if unset)
  NSX_PASSWORD                optional; prefer the prompt
  VPC_ID                      Supervisor namespace VPC id
  AVI_SE_DATANICS_GROUP_ID    Avi SE data-NIC group id (apply-policy)
  SUBNET_ID                   subnet id (ports); or pass it as an argument
  CONFIRM                     set to tagdemo-3tier to skip the delete prompt

Subcommands:
  subnets                     GET the VPC subnets
  groups                      GET the VPC groups (find the id ending in DataNics)
  ports [subnet-id]           GET subnet ports (the objects that carry the tags)
  apply-groups                PATCH tagdemo-web, tagdemo-app, tagdemo-db
  members                     GET members/subnet-ports and members/ip-addresses
  apply-policy                PATCH tagdemo-3tier (substitutes a temp copy)
  policy                      GET tagdemo-3tier
  rules                       GET tagdemo-3tier/rules
  stats                       GET tagdemo-3tier/statistics
  rule-stats <rule-id>        GET one rule's statistics
  infra-policies              GET global policies under domains/default
  delete                      DELETE tagdemo-3tier, then the three groups

The checked-in JSON keeps its placeholders. apply-policy writes a temporary
copy and deletes it on exit.
EOF
}

cleanup() {
  if [[ -n "$CURL_CFG" ]]; then
    rm -f "$CURL_CFG"
  fi
  if [[ -n "$RENDERED" ]]; then
    rm -f "$RENDERED"
  fi
}
trap cleanup EXIT

die() {
  echo "nsx-api.sh: $*" >&2
  exit 1
}

require_id() {
  local name="$1" value="$2"
  if [[ -z "$value" || "$value" == *"<"* || "$value" == *"/"* || "$value" == *" "* || "$value" == *$'\n'* || "$value" == *"?"* || "$value" == *"&"* || "$value" == *"#"* ]]; then
    die "$name is empty or contains a character this script will not put in a URL"
  fi
}

init_target() {
  : "${NSX_MANAGER:?set NSX_MANAGER to the NSX Manager host}"
  : "${NSX_USER:?set NSX_USER to the NSX local user}"
  : "${VPC_ID:?set VPC_ID to the namespace VPC id}"

  NSX_HOST="${NSX_MANAGER#https://}"
  NSX_HOST="${NSX_HOST#http://}"
  NSX_HOST="${NSX_HOST%%/*}"
  [[ -n "$NSX_HOST" ]] || die "NSX_MANAGER is empty"
  require_id NSX_MANAGER "$NSX_HOST"
  require_id VPC_ID "$VPC_ID"
  local bs=$'\\'
  case "$NSX_USER" in
    *:*|*$'\n'*|*'"'*|*"$bs"*)
      die "NSX_USER cannot contain a colon, quote, backslash, or newline"
      ;;
  esac

  NSX="https://${NSX_HOST}"
  V="/policy/api/v1/orgs/default/projects/default/vpcs/${VPC_ID}"
}

init_auth() {
  local password escaped
  if [[ -z "${NSX_PASSWORD:-}" ]]; then
    if [[ ! -t 0 ]]; then
      die "NSX_PASSWORD is unset and stdin is not a terminal"
    fi
    read -r -s -p "Password for ${NSX_USER} at ${NSX_HOST}: " password
    echo
  else
    password="$NSX_PASSWORD"
  fi
  [[ -n "$password" ]] || die "empty password"
  if [[ "$password" == *$'\n'* ]]; then
    die "password cannot contain a newline"
  fi
  # curl's config parser treats \ as an escape inside quotes.
  escaped="${password//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"

  umask 077
  CURL_CFG="$(mktemp)"
  chmod 600 "$CURL_CFG"
  printf 'user = "%s:%s"\n' "$NSX_USER" "$escaped" > "$CURL_CFG"
  unset NSX_PASSWORD password escaped
}

# nsx METHOD URL [curl args...]
# Prints the body on stdout and "HTTP <code>" on stderr.
# Returns non-zero on a non-2xx code.
nsx() {
  local method="$1" url="$2" body code
  shift 2
  body="$(mktemp)"
  code="$(
    curl -sS -k --config "$CURL_CFG" \
      -o "$body" -w '%{http_code}' \
      -X "$method" "$url" "$@"
  )"
  cat "$body"
  echo
  rm -f "$body"
  echo "HTTP ${code}" >&2
  [[ "$code" == 2* ]]
}

nsx_delete() {
  local url="$1" body code
  body="$(mktemp)"
  code="$(
    curl -sS -k --config "$CURL_CFG" \
      -o "$body" -w '%{http_code}' \
      -X DELETE "$url"
  )"
  cat "$body"
  echo
  rm -f "$body"
  echo "HTTP ${code}" >&2
  [[ "$code" == 2* || "$code" == 404 ]]
}

render_policy() {
  local src="$ROOT/policy-3tier.json" text
  [[ -f "$src" ]] || die "missing $src"
  text="$(<"$src")"
  [[ "$text" == *"<vpc-id>"* ]] || die "policy-3tier.json has no <vpc-id> placeholder"
  [[ "$text" == *"<avi-se-datanics-group-id>"* ]] || die "policy-3tier.json has no <avi-se-datanics-group-id> placeholder"
  require_id AVI_SE_DATANICS_GROUP_ID "${AVI_SE_DATANICS_GROUP_ID:-}"
  text="${text//<vpc-id>/$VPC_ID}"
  text="${text//<avi-se-datanics-group-id>/$AVI_SE_DATANICS_GROUP_ID}"
  if [[ "$text" == *"<"* ]]; then
    die "unsubstituted placeholder left in the policy body"
  fi
  umask 077
  RENDERED="$(mktemp)"
  chmod 600 "$RENDERED"
  printf '%s' "$text" > "$RENDERED"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$RENDERED"
  fi
}

apply_groups() {
  local name
  for name in tagdemo-web tagdemo-app tagdemo-db; do
    echo "PATCH groups/${name}" >&2
    nsx PATCH "${NSX}${V}/groups/${name}" \
      -H 'Content-Type: application/json' \
      -d @"${ROOT}/${name}.json"
  done
}

members() {
  local name kind
  for name in tagdemo-web tagdemo-app tagdemo-db; do
    for kind in subnet-ports ip-addresses; do
      echo "GET groups/${name}/members/${kind}" >&2
      nsx GET "${NSX}${V}/groups/${name}/members/${kind}"
    done
  done
}

confirm_delete() {
  local answer="${CONFIRM:-}"
  if [[ "$answer" != "tagdemo-3tier" ]]; then
    if [[ ! -t 0 ]]; then
      die "set CONFIRM=tagdemo-3tier to delete without a prompt"
    fi
    read -r -p "Type tagdemo-3tier to delete the demo policy and groups in VPC ${VPC_ID}: " answer
  fi
  [[ "$answer" == "tagdemo-3tier" ]] || die "aborted"
}

main() {
  local cmd="${1:-}" subnet="" rule="" name=""
  case "$cmd" in
    -h|--help|help)
      usage
      exit 0
      ;;
    "")
      usage >&2
      exit 1
      ;;
  esac
  shift

  case "$cmd" in
    subnets|groups|ports|apply-groups|members|apply-policy|policy|rules|stats|rule-stats|infra-policies|delete)
      ;;
    *)
      die "unknown subcommand: ${cmd} (try --help)"
      ;;
  esac

  if [[ "$cmd" == "ports" ]]; then
    subnet="${1:-${SUBNET_ID:-}}"
    require_id SUBNET_ID "$subnet"
  fi
  if [[ "$cmd" == "apply-policy" ]]; then
    : "${AVI_SE_DATANICS_GROUP_ID:?set AVI_SE_DATANICS_GROUP_ID to the group id ending in DataNics}"
    require_id AVI_SE_DATANICS_GROUP_ID "$AVI_SE_DATANICS_GROUP_ID"
  fi
  if [[ "$cmd" == "rule-stats" ]]; then
    rule="${1:-}"
    case "$rule" in
      tagdemo-a-drop-web-web|\
      tagdemo-b-allow-web-app-8080|\
      tagdemo-c-allow-app-db-5432|\
      tagdemo-e-allow-lb-web-80|\
      tagdemo-d-default-deny)
        ;;
      *)
        die "rule-stats needs one of the five tagdemo rule ids"
        ;;
    esac
  fi

  init_target
  if [[ "$cmd" == "delete" ]]; then
    confirm_delete
  fi
  init_auth

  case "$cmd" in
    subnets)
      nsx GET "${NSX}${V}/subnets"
      ;;
    groups)
      nsx GET "${NSX}${V}/groups"
      ;;
    ports)
      nsx GET "${NSX}${V}/subnets/${subnet}/ports"
      ;;
    apply-groups)
      apply_groups
      ;;
    members)
      members
      ;;
    apply-policy)
      render_policy
      echo "PATCH security-policies/tagdemo-3tier" >&2
      nsx PATCH "${NSX}${V}/security-policies/tagdemo-3tier" \
        -H 'Content-Type: application/json' \
        -d @"${RENDERED}"
      ;;
    policy)
      nsx GET "${NSX}${V}/security-policies/tagdemo-3tier"
      ;;
    rules)
      nsx GET "${NSX}${V}/security-policies/tagdemo-3tier/rules"
      ;;
    stats)
      nsx GET "${NSX}${V}/security-policies/tagdemo-3tier/statistics"
      ;;
    rule-stats)
      nsx GET "${NSX}${V}/security-policies/tagdemo-3tier/rules/${rule}/statistics?enforcement_point_path=/infra/sites/default/enforcement-points/default"
      ;;
    infra-policies)
      nsx GET "${NSX}/policy/api/v1/infra/domains/default/security-policies"
      ;;
    delete)
      echo "DELETE security-policies/tagdemo-3tier" >&2
      nsx_delete "${NSX}${V}/security-policies/tagdemo-3tier"
      for name in tagdemo-web tagdemo-app tagdemo-db; do
        echo "DELETE groups/${name}" >&2
        nsx_delete "${NSX}${V}/groups/${name}"
      done
      ;;
    *)
      die "unknown subcommand: ${cmd} (try --help)"
      ;;
  esac
}

main "$@"
