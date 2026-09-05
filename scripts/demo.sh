#!/usr/bin/env bash
# CLI lab orchestrator: private S3 package repo (gateway VPCE + Syd→Akl CRR,
# dual-OS consumers, guarded publish, Lambda index rebuild, public catalog UI).
# Echoes AWS commands before running them.
#
# Usage: ./scripts/demo.sh <command>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="${ROOT}/.lab-state.json"
TAG_KEY="Project"
TAG_VALUE="private-s3-pkg-repo"
NAME_PREFIX="${NAME_PREFIX:-ps3p}"
PRIMARY_REGION="ap-southeast-2"
REPLICA_REGION="ap-southeast-6"
REPOS_PREFIX="repos/"

# Sample packages (pinned URLs). sha256 is printed at download time in publish.
# RPM: EPEL 9 hello (unsigned lab install on AL2023).
SAMPLE_RPM_URL="https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/Packages/h/hello-2.12.2-1.el9.x86_64.rpm"
SAMPLE_RPM_FILE="hello-2.12.2-1.el9.x86_64.rpm"
SAMPLE_RPM_NAME="hello"
# Deb: Ubuntu archive hello (amd64).
SAMPLE_DEB_URL="http://archive.ubuntu.com/ubuntu/pool/main/h/hello/hello_2.10-3build1_amd64.deb"
SAMPLE_DEB_FILE="hello_2.10-3build1_amd64.deb"
SAMPLE_DEB_NAME="hello"

RPM_TREE="repos/rpm/al2023/x86_64"
DEB_TREE="repos/deb/ubuntu/noble"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./scripts/demo.sh <command>

Commands:
  up-shared              Private pkgs buckets + CRR (repos/) + UI bucket + IAM + rebuild Lambda
  up-consumer syd|akl    VPC + gateway VPCE + SSM endpoints + AL2023 + Ubuntu EC2
  allowlist              Lock package-bucket GetObject to VPCE IDs (UI stays public)
  publish                Download sample rpm/deb, publisher Put; EventBridge rebuild; wait CRR
  open-ui                Print public UI bucket website endpoint URL
  prove syd|akl          SSM dnf/apt install on both OS probes in that region
  status                 Show .lab-state.json summary (read-only)
  down                   Tear down lab (auth check, state.bak, verify before clear)

Required environment:
  AWS_PROFILE   Named profile (e.g. sandbox)

Optional:
  LAB_SUFFIX  NAME_PREFIX
EOF
}

run() {
  printf '+ %s\n' "$*" >&2
  "$@"
}

require_env() {
  [[ -n "${AWS_PROFILE:-}" ]] || die "AWS_PROFILE is unset"
  command -v aws >/dev/null || die "aws CLI not found"
  command -v jq >/dev/null || die "jq not found"
}

account_id() {
  aws sts get-caller-identity --query Account --output text
}

caller_arn() {
  aws sts get-caller-identity --query Arn --output text
}

resolve_bypass_principal() {
  local admin_arn bypass="" role_name
  admin_arn="$(caller_arn)"
  # Prefer the IAM role ARN (SSO permission sets live under aws-reserved/…).
  # Never put an STS session ARN in a bucket policy Principal.
  if [[ "$admin_arn" == *assumed-role* ]]; then
    role_name="${admin_arn#*assumed-role/}"
    role_name="${role_name%%/*}"
    if [[ -n "$role_name" ]]; then
      bypass="$(aws iam get-role --role-name "$role_name" --query Role.Arn --output text 2>/dev/null || true)"
    fi
  elif [[ "$admin_arn" == arn:aws:iam::* ]]; then
    bypass="$admin_arn"
  fi
  [[ -n "$bypass" && "$bypass" == arn:aws:iam::* ]] || \
    die "could not resolve IAM role ARN for bucket policy bypass (caller=$admin_arn)"
  printf '%s\n' "$bypass"
}

state_init() {
  if [[ ! -f "$STATE_FILE" ]]; then
    local suffix="${LAB_SUFFIX:-$(date -u +%Y%m%d%H%M%S)}"
    local acct
    acct="$(account_id)"
    cat >"$STATE_FILE" <<EOF
{
  "suffix": "$suffix",
  "account_id": "$acct",
  "name_prefix": "$NAME_PREFIX",
  "primary_region": "$PRIMARY_REGION",
  "replica_region": "$REPLICA_REGION",
  "repos_prefix": "$REPOS_PREFIX",
  "consumers": {}
}
EOF
  fi
}

state_get() {
  jq -r "$1" "$STATE_FILE"
}

state_set() {
  local filter="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  jq --argjson v "$value" "$filter = \$v" "$STATE_FILE" >"$tmp"
  mv "$tmp" "$STATE_FILE"
}

state_set_str() {
  local filter="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg v "$value" "$filter = \$v" "$STATE_FILE" >"$tmp"
  mv "$tmp" "$STATE_FILE"
}

cmd_status() {
  require_env
  [[ -f "$STATE_FILE" ]] || die "no state file; run up-shared first"
  jq . "$STATE_FILE"
}

ensure_bucket() {
  local bucket="$1" region="$2"
  if aws s3api head-bucket --bucket "$bucket" --region "$region" 2>/dev/null; then
    printf 'bucket exists: %s\n' "$bucket" >&2
    return 0
  fi
  if [[ "$region" == "us-east-1" ]]; then
    run aws s3api create-bucket --bucket "$bucket" --region "$region"
  else
    run aws s3api create-bucket --bucket "$bucket" --region "$region" \
      --create-bucket-configuration "LocationConstraint=$region"
  fi
  run aws s3api put-bucket-tagging --bucket "$bucket" --region "$region" \
    --tagging "TagSet=[{Key=$TAG_KEY,Value=$TAG_VALUE}]"
  run aws s3api put-public-access-block --bucket "$bucket" --region "$region" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  run aws s3api put-bucket-ownership-controls --bucket "$bucket" --region "$region" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
  run aws s3api put-bucket-versioning --bucket "$bucket" --region "$region" \
    --versioning-configuration Status=Enabled
  run aws s3api put-bucket-encryption --bucket "$bucket" --region "$region" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
}

# Public static website bucket (catalog viewer only — not package objects).
ensure_ui_bucket() {
  local bucket="$1" region="$2"
  if aws s3api head-bucket --bucket "$bucket" --region "$region" 2>/dev/null; then
    printf 'ui bucket exists: %s\n' "$bucket" >&2
  else
    run aws s3api create-bucket --bucket "$bucket" --region "$region" \
      --create-bucket-configuration "LocationConstraint=$region"
    run aws s3api put-bucket-tagging --bucket "$bucket" --region "$region" \
      --tagging "TagSet=[{Key=$TAG_KEY,Value=$TAG_VALUE}]"
    run aws s3api put-bucket-ownership-controls --bucket "$bucket" --region "$region" \
      --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
    run aws s3api put-bucket-encryption --bucket "$bucket" --region "$region" \
      --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  fi
  # Website hosting requires public Get; unblock policy + public ACLs block.
  run aws s3api put-public-access-block --bucket "$bucket" --region "$region" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false"
  run aws s3api put-bucket-website --bucket "$bucket" --region "$region" \
    --website-configuration '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"index.html"}}'
  local policy
  # S3 website endpoints are HTTP-only without CloudFront — do not deny non-TLS here.
  policy="$(jq -n --arg b "$bucket" '{
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "PublicReadWebsite",
        Effect: "Allow",
        Principal: "*",
        Action: "s3:GetObject",
        Resource: "arn:aws:s3:::\($b)/*"
      }
    ]
  }')"
  run aws s3api put-bucket-policy --bucket "$bucket" --region "$region" --policy "$policy"
}

sync_catalog_ui() {
  local bucket="$1" region="$2"
  local ui_dir="${ROOT}/catalog-ui"
  [[ -d "$ui_dir" ]] || die "missing catalog-ui/ at $ui_dir"
  run aws s3 sync "$ui_dir" "s3://${bucket}/" --region "$region" \
    --exclude '*.md' --exclude '.git*'
  # Seed empty catalog if absent so the page loads before first publish.
  if ! aws s3api head-object --bucket "$bucket" --key catalog.json --region "$region" >/dev/null 2>&1; then
    local seed
    seed="$(mktemp)"
    printf '%s\n' '{"generated_at":null,"packages":[]}' >"$seed"
    run aws s3 cp "$seed" "s3://${bucket}/catalog.json" --region "$region" \
      --content-type application/json
    rm -f "$seed"
  fi
}

put_role_policy_retry() {
  local role="$1" pname="$2" doc="$3" i
  for i in 1 2 3 4 5 6; do
    if aws iam put-role-policy --role-name "$role" --policy-name "$pname" --policy-document "$doc"; then
      return 0
    fi
    sleep 3
  done
  die "put-role-policy failed for $role/$pname"
}

# Create or reuse lab GPG key in Secrets Manager; publish armored public key.
# Prints secret ARN on stdout; progress on stderr.
ensure_gpg_signing() {
  local suffix="$1" ui_bucket="$2" primary="$3"
  local secret_name="${NAME_PREFIX}-gpg-${suffix}"
  local secret_arn pubkey_pkg="repos/gpg/lab-signing.asc" pubkey_ui="gpg/lab-signing.asc"
  local work gnupg priv pub

  command -v gpg >/dev/null 2>&1 || die "gpg required to create the lab signing key"

  if secret_arn="$(aws secretsmanager describe-secret --region "$PRIMARY_REGION" \
      --secret-id "$secret_name" --query ARN --output text 2>/dev/null)"; then
    printf 'reusing GPG secret %s\n' "$secret_arn" >&2
  else
    work="$(mktemp -d)"
    gnupg="$work/gnupg"
    mkdir -m 700 "$gnupg"
    export GNUPGHOME="$gnupg"
    cat >"$work/keyparams" <<'EOF'
%no-protection
Key-Type: RSA
Key-Length: 3072
Name-Real: private-s3-pkg-repo lab
Name-Email: lab@ps3p.example
Expire-Date: 0
%commit
EOF
    printf 'generating lab GPG signing key...\n' >&2
    gpg --batch --generate-key "$work/keyparams"
    priv="$work/private.asc"
    pub="$work/public.asc"
    gpg --batch --armor --export-secret-keys >"$priv"
    gpg --batch --armor --export >"$pub"
    [[ -s "$priv" && -s "$pub" ]] || die "gpg key export failed"
    printf '+ aws secretsmanager create-secret --name %s ...\n' "$secret_name" >&2
    secret_arn="$(aws secretsmanager create-secret --region "$PRIMARY_REGION" \
      --name "$secret_name" \
      --description "private-s3-pkg-repo lab repo-metadata signing key" \
      --secret-string "file://${priv}" \
      --tags "Key=$TAG_KEY,Value=$TAG_VALUE" \
      --query ARN --output text)"
    unset GNUPGHOME
    rm -rf "$work"
    printf 'created GPG secret %s\n' "$secret_arn" >&2
    # Secrets Manager is briefly eventually consistent after create.
    local i
    for i in 1 2 3 4 5 6 7 8; do
      if aws secretsmanager get-secret-value --region "$PRIMARY_REGION" \
          --secret-id "$secret_arn" --query ARN --output text >/dev/null 2>&1; then
        break
      fi
      sleep 2
      [[ "$i" -eq 8 ]] && die "secret $secret_arn not readable after create"
    done
  fi

  # Publish public key from the secret (works for create and reuse).
  work="$(mktemp -d)"
  gnupg="$work/gnupg"
  mkdir -m 700 "$gnupg"
  export GNUPGHOME="$gnupg"
  local i imported=0
  for i in 1 2 3 4 5 6 7 8; do
    if aws secretsmanager get-secret-value --region "$PRIMARY_REGION" --secret-id "$secret_arn" \
        --query SecretString --output text 2>/dev/null \
        | gpg --batch --import >/dev/null 2>&1; then
      imported=1
      break
    fi
    sleep 2
  done
  [[ "$imported" -eq 1 ]] || die "failed to import private key from secret"
  pub="$work/public.asc"
  gpg --batch --armor --export >"$pub"
  [[ -s "$pub" ]] || die "failed to export public key from secret"
  run aws s3 cp "$pub" "s3://${primary}/${pubkey_pkg}" --region "$PRIMARY_REGION" \
    --content-type application/pgp-keys >/dev/null
  run aws s3 cp "$pub" "s3://${ui_bucket}/${pubkey_ui}" --region "$PRIMARY_REGION" \
    --content-type application/pgp-keys >/dev/null
  unset GNUPGHOME
  rm -rf "$work"

  state_set_str '.gpg_secret_name' "$secret_name"
  state_set_str '.gpg_secret_arn' "$secret_arn"
  state_set_str '.gpg_pubkey_key' "$pubkey_pkg"
  state_set_str '.gpg_pubkey_ui_key' "$pubkey_ui"
  printf '%s\n' "$secret_arn"
}

cmd_up_shared() {
  require_env
  export AWS_REGION="$PRIMARY_REGION" AWS_DEFAULT_REGION="$PRIMARY_REGION"
  state_init
  local acct suffix primary replica ui_bucket crr_role pub_role lam_role
  acct="$(state_get .account_id)"
  suffix="$(state_get .suffix)"
  primary="${NAME_PREFIX}-pkgs-${acct}-syd"
  replica="${NAME_PREFIX}-pkgs-${acct}-akl"
  ui_bucket="${NAME_PREFIX}-ui-${acct}-syd"
  crr_role="${NAME_PREFIX}-crr-${suffix}"
  pub_role="${NAME_PREFIX}-publisher-${suffix}"
  lam_role="${NAME_PREFIX}-rebuild-${suffix}"

  ensure_bucket "$primary" "$PRIMARY_REGION"
  ensure_bucket "$replica" "$REPLICA_REGION"
  state_set_str '.primary_bucket' "$primary"
  state_set_str '.replica_bucket' "$replica"

  ensure_ui_bucket "$ui_bucket" "$PRIMARY_REGION"
  state_set_str '.ui_bucket' "$ui_bucket"
  sync_catalog_ui "$ui_bucket" "$PRIMARY_REGION"

  # --- CRR role ---
  if ! aws iam get-role --role-name "$crr_role" >/dev/null 2>&1; then
    run aws iam create-role --role-name "$crr_role" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"s3.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
      --tags "Key=$TAG_KEY,Value=$TAG_VALUE"
  fi
  local crr_policy
  crr_policy="$(jq -n --arg primary "$primary" --arg replica "$replica" '{
    Version: "2012-10-17",
    Statement: [
      {
        Effect: "Allow",
        Action: ["s3:GetReplicationConfiguration", "s3:ListBucket"],
        Resource: ["arn:aws:s3:::\($primary)"]
      },
      {
        Effect: "Allow",
        Action: [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ],
        Resource: ["arn:aws:s3:::\($primary)/*"]
      },
      {
        Effect: "Allow",
        Action: [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags",
          "s3:ObjectOwnerOverrideToBucketOwner"
        ],
        Resource: ["arn:aws:s3:::\($replica)/*"]
      }
    ]
  }')"
  run aws iam put-role-policy --role-name "$crr_role" --policy-name crr \
    --policy-document "$crr_policy"
  local crr_role_arn
  crr_role_arn="$(aws iam get-role --role-name "$crr_role" --query Role.Arn --output text)"
  state_set_str '.crr_role_arn' "$crr_role_arn"

  run aws s3api put-bucket-replication --bucket "$primary" --region "$PRIMARY_REGION" \
    --replication-configuration "$(jq -n \
      --arg role "$crr_role_arn" \
      --arg replica "$replica" \
      --arg prefix "$REPOS_PREFIX" '{
        Role: $role,
        Rules: [{
          ID: "repos-to-akl",
          Status: "Enabled",
          Priority: 1,
          Filter: {Prefix: $prefix},
          DeleteMarkerReplication: {Status: "Enabled"},
          Destination: {Bucket: "arn:aws:s3:::\($replica)", StorageClass: "STANDARD"}
        }]
      }')"

  local bypass
  bypass="$(resolve_bypass_principal)"
  state_set_str '.bypass_principal_arn' "$bypass"

  # --- Publisher role (Put under Packages/ and pool/ only) ---
  if ! aws iam get-role --role-name "$pub_role" >/dev/null 2>&1; then
    run aws iam create-role --role-name "$pub_role" \
      --assume-role-policy-document "$(jq -n --arg bypass "$bypass" '{
        Version: "2012-10-17",
        Statement: [{
          Effect: "Allow",
          Principal: {AWS: $bypass},
          Action: "sts:AssumeRole"
        }]
      }')" \
      --tags "Key=$TAG_KEY,Value=$TAG_VALUE"
  fi
  local pub_policy
  pub_policy="$(jq -n --arg b "$primary" '{
    Version: "2012-10-17",
    Statement: [
      {
        Effect: "Allow",
        Action: ["s3:ListBucket"],
        Resource: ["arn:aws:s3:::\($b)"],
        Condition: {StringLike: {"s3:prefix": ["repos/*"]}}
      },
      {
        Effect: "Allow",
        Action: ["s3:PutObject"],
        Resource: [
          "arn:aws:s3:::\($b)/repos/*/Packages/*",
          "arn:aws:s3:::\($b)/repos/*/pool/*"
        ]
      }
    ]
  }')"
  put_role_policy_retry "$pub_role" publisher "$pub_policy"
  local pub_role_arn
  pub_role_arn="$(aws iam get-role --role-name "$pub_role" --query Role.Arn --output text)"
  state_set_str '.publisher_role_arn' "$pub_role_arn"

  # --- Rebuild Lambda execution role ---
  if ! aws iam get-role --role-name "$lam_role" >/dev/null 2>&1; then
    run aws iam create-role --role-name "$lam_role" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
      --tags "Key=$TAG_KEY,Value=$TAG_VALUE"
  fi
  run aws iam attach-role-policy --role-name "$lam_role" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole || true

  local gpg_secret_arn
  gpg_secret_arn="$(ensure_gpg_signing "$suffix" "$ui_bucket" "$primary")"

  local lam_policy
  lam_policy="$(jq -n --arg pkg "$primary" --arg ui "$ui_bucket" --arg secret "$gpg_secret_arn" '{
    Version: "2012-10-17",
    Statement: [
      {
        Effect: "Allow",
        Action: ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
        Resource: [
          "arn:aws:s3:::\($pkg)",
          "arn:aws:s3:::\($pkg)/*"
        ]
      },
      {
        Effect: "Allow",
        Action: ["s3:ListBucket", "s3:GetObject", "s3:PutObject"],
        Resource: [
          "arn:aws:s3:::\($ui)",
          "arn:aws:s3:::\($ui)/*"
        ]
      },
      {
        Effect: "Allow",
        Action: ["secretsmanager:GetSecretValue"],
        Resource: [$secret]
      }
    ]
  }')"
  put_role_policy_retry "$lam_role" rebuild "$lam_policy"
  local lam_role_arn
  lam_role_arn="$(aws iam get-role --role-name "$lam_role" --query Role.Arn --output text)"
  state_set_str '.rebuild_lambda_role_arn' "$lam_role_arn"

  # Bootstrap package-bucket policies (admin + CRR + publisher + lambda; VPCE lock later).
  write_openish_pkg_policy() {
    local bucket="$1" region="$2"
    local principals_json doc i
    principals_json="$(jq -n \
      --arg crr "$crr_role_arn" \
      --arg bypass "$bypass" \
      --arg pub "$pub_role_arn" \
      --arg lam "$lam_role_arn" \
      '[$bypass, $crr, $pub, $lam] | unique')"
    doc="$(jq -n --arg bucket "$bucket" --argjson principals "$principals_json" '
      {
        Version: "2012-10-17",
        Statement: [
          {
            Sid: "AllowBypassPrincipals",
            Effect: "Allow",
            Principal: {
              AWS: (if ($principals | length) == 1 then $principals[0] else $principals end)
            },
            Action: "s3:*",
            Resource: ["arn:aws:s3:::\($bucket)", "arn:aws:s3:::\($bucket)/*"]
          },
          {
            Sid: "AllowSSLRequestsOnly",
            Effect: "Deny",
            Principal: "*",
            Action: "s3:*",
            Resource: ["arn:aws:s3:::\($bucket)", "arn:aws:s3:::\($bucket)/*"],
            Condition: {Bool: {"aws:SecureTransport": "false"}}
          }
        ]
      }
    ')"
    for i in 1 2 3 4 5 6 7 8 9 10; do
      printf '+ aws s3api put-bucket-policy --bucket %s --region %s ...\n' "$bucket" "$region" >&2
      if aws s3api put-bucket-policy --bucket "$bucket" --region "$region" --policy "$doc"; then
        return 0
      fi
      printf 'warn: put-bucket-policy %s failed (try %s/10); waiting for IAM propagation\n' \
        "$bucket" "$i" >&2
      sleep 5
    done
    die "put-bucket-policy failed for $bucket after retries"
  }

  write_openish_pkg_policy "$primary" "$PRIMARY_REGION"
  write_openish_pkg_policy "$replica" "$REPLICA_REGION"

  # EventBridge notifications on primary package bucket.
  run aws s3api put-bucket-notification-configuration \
    --bucket "$primary" --region "$PRIMARY_REGION" \
    --notification-configuration '{"EventBridgeConfiguration": {}}'

  deploy_rebuild_lambda "$primary" "$ui_bucket" "$lam_role_arn" "$suffix" "$acct" "$gpg_secret_arn"

  local website
  website="http://${ui_bucket}.s3-website-${PRIMARY_REGION}.amazonaws.com"
  state_set_str '.ui_website_url' "$website"
  printf 'up-shared complete: %s → %s; ui=%s\n' "$primary" "$replica" "$website" >&2
}

# Build/push container image, create/update Lambda, EventBridge rule on package Put.
# Docker is required — index rebuild always runs in Lambda (no laptop fallback).
deploy_rebuild_lambda() {
  local primary="$1" ui_bucket="$2" lam_role_arn="$3" suffix="$4" acct="$5" gpg_secret_arn="$6"
  local ecr_repo fn_name rule_name image_uri repo_uri
  ecr_repo="${NAME_PREFIX}-rebuild"
  fn_name="${NAME_PREFIX}-rebuild-${suffix}"
  rule_name="${NAME_PREFIX}-pkg-put-${suffix}"
  [[ -n "$gpg_secret_arn" ]] || die "missing GPG_SECRET_ARN for rebuild Lambda"

  state_set_str '.ecr_repository' "$ecr_repo"
  state_set_str '.rebuild_lambda_name' "$fn_name"
  state_set_str '.eventbridge_rule_name' "$rule_name"

  command -v docker >/dev/null 2>&1 || die "docker required to build the rebuild Lambda image"
  [[ -f "${ROOT}/lambda/rebuild/Dockerfile" ]] || die "missing ${ROOT}/lambda/rebuild/Dockerfile"

  if ! aws ecr describe-repositories --region "$PRIMARY_REGION" --repository-names "$ecr_repo" >/dev/null 2>&1; then
    run aws ecr create-repository --region "$PRIMARY_REGION" --repository-name "$ecr_repo" \
      --tags "Key=$TAG_KEY,Value=$TAG_VALUE"
  fi
  repo_uri="$(aws ecr describe-repositories --region "$PRIMARY_REGION" --repository-names "$ecr_repo" \
    --query 'repositories[0].repositoryUri' --output text)"
  image_uri="${repo_uri}:latest"

  printf '+ aws ecr get-login-password | docker login ...\n' >&2
  aws ecr get-login-password --region "$PRIMARY_REGION" \
    | docker login --username AWS --password-stdin "${repo_uri%%/*}" >/dev/null

  printf '+ docker build -t %s %s/lambda/rebuild\n' "$image_uri" "$ROOT" >&2
  docker build -t "$image_uri" "${ROOT}/lambda/rebuild"
  printf '+ docker push %s\n' "$image_uri" >&2
  docker push "$image_uri"

  # IAM role propagation for Lambda
  local i
  for i in 1 2 3 4 5 6; do
    if aws lambda get-function --region "$PRIMARY_REGION" --function-name "$fn_name" >/dev/null 2>&1; then
      run aws lambda update-function-code --region "$PRIMARY_REGION" \
        --function-name "$fn_name" --image-uri "$image_uri" >/dev/null
      run aws lambda wait function-updated --region "$PRIMARY_REGION" --function-name "$fn_name" || true
      run aws lambda update-function-configuration --region "$PRIMARY_REGION" \
        --function-name "$fn_name" \
        --timeout 300 --memory-size 2048 \
        --environment "Variables={PACKAGE_BUCKET=${primary},UI_BUCKET=${ui_bucket},GPG_SECRET_ARN=${gpg_secret_arn}}" >/dev/null
      break
    fi
    if run aws lambda create-function --region "$PRIMARY_REGION" \
      --function-name "$fn_name" \
      --package-type Image \
      --code "ImageUri=${image_uri}" \
      --role "$lam_role_arn" \
      --timeout 300 --memory-size 2048 \
      --environment "Variables={PACKAGE_BUCKET=${primary},UI_BUCKET=${ui_bucket},GPG_SECRET_ARN=${gpg_secret_arn}}" \
      --tags "${TAG_KEY}=${TAG_VALUE}" >/dev/null 2>&1; then
      break
    fi
    printf 'warn: create-function failed (try %s/6); waiting for IAM\n' "$i" >&2
    sleep 8
  done

  local lam_arn
  lam_arn="$(aws lambda get-function --region "$PRIMARY_REGION" --function-name "$fn_name" \
    --query 'Configuration.FunctionArn' --output text)"
  state_set_str '.rebuild_lambda_arn' "$lam_arn"

  # EventBridge: Object Created for package blobs under the fixed trees.
  # Prefix-only (one matcher key per expression). Array entries are OR'd.
  # Indexes land under repodata/ and dists/, not Packages/ or pool/.
  local pattern
  pattern="$(jq -n --arg b "$primary" \
    --arg rpm "${RPM_TREE}/Packages/" \
    --arg deb "${DEB_TREE}/pool/" '{
    source: ["aws.s3"],
    "detail-type": ["Object Created"],
    detail: {
      bucket: {name: [$b]},
      object: {
        key: [
          {prefix: $rpm},
          {prefix: $deb}
        ]
      }
    }
  }')"
  run aws events put-rule --region "$PRIMARY_REGION" --name "$rule_name" \
    --event-pattern "$pattern" --state ENABLED \
    --tags "Key=$TAG_KEY,Value=$TAG_VALUE" >/dev/null
  run aws lambda add-permission --region "$PRIMARY_REGION" --function-name "$fn_name" \
    --statement-id "events-${rule_name}" \
    --action lambda:InvokeFunction \
    --principal events.amazonaws.com \
    --source-arn "arn:aws:events:${PRIMARY_REGION}:${acct}:rule/${rule_name}" 2>/dev/null || true
  run aws events put-targets --region "$PRIMARY_REGION" --rule "$rule_name" \
    --targets "Id=1,Arn=${lam_arn}"

  printf 'rebuild Lambda ready: %s\n' "$lam_arn" >&2
}

# Userdata: enable/start SSM agent if already present — never apt/dnf install it.
ssm_userdata() {
  cat <<'USERDATA'
#!/bin/bash
set -eux
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable amazon-ssm-agent 2>/dev/null || true
  systemctl start amazon-ssm-agent 2>/dev/null || true
  systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service 2>/dev/null || true
  systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service 2>/dev/null || true
fi
if command -v snap >/dev/null 2>&1; then
  snap start amazon-ssm-agent 2>/dev/null || true
fi
USERDATA
}

lookup_al2023_ami() {
  local region="$1"
  aws ec2 describe-images --region "$region" --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text
}

lookup_ubuntu_ami() {
  local region="$1"
  # Canonical owner; prefer gp3 noble, fall back to hvm-ssd.
  local ami
  ami="$(aws ec2 describe-images --region "$region" --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
              "Name=state,Values=available" \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text 2>/dev/null || true)"
  if [[ -z "$ami" || "$ami" == "None" ]]; then
    ami="$(aws ec2 describe-images --region "$region" --owners 099720109477 \
      --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-noble-24.04-amd64-server-*" \
                "Name=state,Values=available" \
      --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)"
  fi
  printf '%s\n' "$ami"
}

cmd_up_consumer() {
  require_env
  local which="${1:-}"
  [[ "$which" == "syd" || "$which" == "akl" ]] || die "up-consumer requires syd|akl"
  [[ -f "$STATE_FILE" ]] || die "run up-shared first"

  local existing
  existing="$(jq -r --arg w "$which" '.consumers[$w].vpc_id // empty' "$STATE_FILE")"
  [[ -z "$existing" ]] || die "consumer $which already exists (vpc=$existing); run down first"

  local region bucket vpc_cidr subnet_cidr
  if [[ "$which" == "syd" ]]; then
    region="$PRIMARY_REGION"
    bucket="$(state_get .primary_bucket)"
    vpc_cidr="10.80.0.0/16"
    subnet_cidr="10.80.1.0/24"
  else
    region="$REPLICA_REGION"
    bucket="$(state_get .replica_bucket)"
    vpc_cidr="10.81.0.0/16"
    subnet_cidr="10.81.1.0/24"
  fi
  [[ -n "$bucket" && "$bucket" != "null" ]] || die "missing bucket in state; run up-shared first"
  # Pin both: a sticky AWS_REGION from the shell overrides AWS_DEFAULT_REGION.
  export AWS_REGION="$region" AWS_DEFAULT_REGION="$region"
  local suffix
  suffix="$(state_get .suffix)"
  local name="${NAME_PREFIX}-${which}-${suffix}"

  local az vpc_id subnet_id rtb_id
  az="$(aws ec2 describe-availability-zones --region "$region" \
    --query 'AvailabilityZones[0].ZoneName' --output text)"
  vpc_id="$(run aws ec2 create-vpc --region "$region" --cidr-block "$vpc_cidr" \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=Name,Value=${name}-vpc}]" \
    --query 'Vpc.VpcId' --output text)"
  run aws ec2 modify-vpc-attribute --region "$region" --vpc-id "$vpc_id" --enable-dns-support
  run aws ec2 modify-vpc-attribute --region "$region" --vpc-id "$vpc_id" --enable-dns-hostnames
  subnet_id="$(run aws ec2 create-subnet --region "$region" --vpc-id "$vpc_id" --cidr-block "$subnet_cidr" \
    --availability-zone "$az" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=Name,Value=${name}-subnet}]" \
    --query 'Subnet.SubnetId' --output text)"
  rtb_id="$(run aws ec2 create-route-table --region "$region" --vpc-id "$vpc_id" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=Name,Value=${name}-rtb}]" \
    --query 'RouteTable.RouteTableId' --output text)"
  run aws ec2 associate-route-table --region "$region" --route-table-id "$rtb_id" --subnet-id "$subnet_id" >/dev/null

  local gateway_vpce_id
  gateway_vpce_id="$(run aws ec2 create-vpc-endpoint --region "$region" \
    --vpc-id "$vpc_id" \
    --vpc-endpoint-type Gateway \
    --service-name "com.amazonaws.${region}.s3" \
    --route-table-ids "$rtb_id" \
    --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=Name,Value=${name}-s3}]" \
    --query 'VpcEndpoint.VpcEndpointId' --output text)"

  # Shared instance profile for both OS probes in this region.
  local role="${name}-ec2"
  if ! aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    run aws iam create-role --role-name "$role" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
      --tags "Key=$TAG_KEY,Value=$TAG_VALUE"
  fi
  run aws iam attach-role-policy --role-name "$role" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  run aws iam put-role-policy --role-name "$role" --policy-name package-read \
    --policy-document "$(jq -n --arg b "$bucket" '{
      Version: "2012-10-17",
      Statement: [{
        Effect: "Allow",
        Action: ["s3:GetObject", "s3:ListBucket"],
        Resource: ["arn:aws:s3:::\($b)", "arn:aws:s3:::\($b)/*"]
      }]
    }')"
  if ! aws iam get-instance-profile --instance-profile-name "$role" >/dev/null 2>&1; then
    run aws iam create-instance-profile --instance-profile-name "$role"
    run aws iam add-role-to-instance-profile --instance-profile-name "$role" --role-name "$role"
    sleep 8
  fi

  local sg_ec2 sg_ssm
  sg_ec2="$(run aws ec2 create-security-group --region "$region" --group-name "${name}-ec2" --description "probe" \
    --vpc-id "$vpc_id" --query GroupId --output text)"
  run aws ec2 create-tags --region "$region" --resources "$sg_ec2" --tags "Key=$TAG_KEY,Value=$TAG_VALUE" "Key=Name,Value=${name}-ec2"
  run aws ec2 authorize-security-group-egress --region "$region" --group-id "$sg_ec2" \
    --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]" || true

  sg_ssm="$(run aws ec2 create-security-group --region "$region" --group-name "${name}-ssm" --description "ssm vpce" \
    --vpc-id "$vpc_id" --query GroupId --output text)"
  run aws ec2 create-tags --region "$region" --resources "$sg_ssm" --tags "Key=$TAG_KEY,Value=$TAG_VALUE" "Key=Name,Value=${name}-ssm"
  run aws ec2 authorize-security-group-ingress --region "$region" --group-id "$sg_ssm" \
    --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$vpc_cidr}]"
  run aws ec2 authorize-security-group-egress --region "$region" --group-id "$sg_ssm" \
    --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]" || true

  # SSM interface endpoints. Skip ec2messages in akl if missing (sibling logic).
  local ssm_vpces=()
  for svc in ssm ssmmessages ec2messages; do
    local id
    if id="$(aws ec2 create-vpc-endpoint --region "$region" \
      --vpc-id "$vpc_id" \
      --vpc-endpoint-type Interface \
      --service-name "com.amazonaws.${region}.${svc}" \
      --subnet-ids "$subnet_id" \
      --security-group-ids "$sg_ssm" \
      --private-dns-enabled \
      --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=Name,Value=${name}-${svc}}]" \
      --query 'VpcEndpoint.VpcEndpointId' --output text)"; then
      printf '+ created interface endpoint %s -> %s\n' "$svc" "$id" >&2
      ssm_vpces+=("$id")
    else
      printf 'warn: skipping interface endpoint %s in %s (service unavailable)\n' "$svc" "$region" >&2
    fi
  done
  [[ ${#ssm_vpces[@]} -ge 2 ]] || die "need at least ssm + ssmmessages VPCEs in $region"

  # AWS CLI base64-encodes --user-data for us; pass the script via file://.
  local ud_file
  ud_file="$(mktemp)"
  ssm_userdata >"$ud_file"

  local ami_al ami_ub iid_al iid_ub
  ami_al="$(lookup_al2023_ami "$region")"
  ami_ub="$(lookup_ubuntu_ami "$region")"
  [[ -n "$ami_al" && "$ami_al" != "None" ]] || die "no AL2023 AMI in $region"
  [[ -n "$ami_ub" && "$ami_ub" != "None" ]] || die "no Ubuntu 24.04 AMI in $region"

  iid_al="$(run aws ec2 run-instances --region "$region" \
    --image-id "$ami_al" \
    --instance-type t3.micro \
    --subnet-id "$subnet_id" \
    --security-group-ids "$sg_ec2" \
    --iam-instance-profile "Name=$role" \
    --user-data "file://${ud_file}" \
    --no-associate-public-ip-address \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=Name,Value=${name}-al2023}]" \
    --query 'Instances[0].InstanceId' --output text)"

  iid_ub="$(run aws ec2 run-instances --region "$region" \
    --image-id "$ami_ub" \
    --instance-type t3.micro \
    --subnet-id "$subnet_id" \
    --security-group-ids "$sg_ec2" \
    --iam-instance-profile "Name=$role" \
    --user-data "file://${ud_file}" \
    --no-associate-public-ip-address \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=Name,Value=${name}-ubuntu}]" \
    --query 'Instances[0].InstanceId' --output text)"
  rm -f "$ud_file"

  local vpces_json
  if [[ ${#ssm_vpces[@]} -eq 0 ]]; then
    vpces_json='[]'
  else
    vpces_json="$(jq -n --args '$ARGS.positional' -- "${ssm_vpces[@]}")"
  fi

  local tmp
  tmp="$(mktemp)"
  jq --arg which "$which" \
    --arg region "$region" \
    --arg bucket "$bucket" \
    --arg vpc "$vpc_id" \
    --arg subnet "$subnet_id" \
    --arg rtb "$rtb_id" \
    --arg vpce "$gateway_vpce_id" \
    --arg iid_al "$iid_al" \
    --arg iid_ub "$iid_ub" \
    --arg ami_al "$ami_al" \
    --arg ami_ub "$ami_ub" \
    --arg role "$role" \
    --arg sg_ec2 "$sg_ec2" \
    --arg sg_ssm "$sg_ssm" \
    --argjson ssm_vpces "$vpces_json" \
    '.consumers[$which] = {
      region:$region, bucket:$bucket,
      vpc_id:$vpc, subnet_id:$subnet, route_table_id:$rtb, created_vpc:true,
      gateway_vpce_id:$vpce, s3_vpce_id:$vpce, created_s3_vpce:true,
      instance_profile:$role, role_name:$role,
      sg_ec2:$sg_ec2, sg_ssm:$sg_ssm, ssm_vpce_ids:$ssm_vpces,
      al2023: {instance_id:$iid_al, ami_id:$ami_al, os:"al2023"},
      ubuntu: {instance_id:$iid_ub, ami_id:$ami_ub, os:"ubuntu"}
    }' "$STATE_FILE" >"$tmp"
  mv "$tmp" "$STATE_FILE"
  printf 'up-consumer %s complete: vpc=%s al2023=%s ubuntu=%s gateway_vpce=%s\n' \
    "$which" "$vpc_id" "$iid_al" "$iid_ub" "$gateway_vpce_id" >&2
}

cmd_allowlist() {
  require_env
  [[ -f "$STATE_FILE" ]] || die "missing state"
  local primary replica crr_role bypass pub_role lam_role
  primary="$(state_get .primary_bucket)"
  replica="$(state_get .replica_bucket)"
  crr_role="$(state_get .crr_role_arn)"
  bypass="$(state_get .bypass_principal_arn)"
  pub_role="$(state_get .publisher_role_arn)"
  lam_role="$(state_get .rebuild_lambda_role_arn)"

  # Collect gateway VPCEs (new + legacy field names).
  local syd_vpces akl_vpces
  syd_vpces="$(jq -c '[.consumers[]? | select(.region=="ap-southeast-2") | (.gateway_vpce_id // .s3_vpce_id)] | unique' "$STATE_FILE")"
  akl_vpces="$(jq -c '[.consumers[]? | select(.region=="ap-southeast-6") | (.gateway_vpce_id // .s3_vpce_id)] | unique' "$STATE_FILE")"

  put_locked_pkg_policy() {
    local bucket="$1" region="$2" vpces_json="$3"
    local doc
    # Deny GetObject unless VPCE; exempt admin/CRR/publisher/lambda.
    # Publisher Put and Lambda index writes remain allowed via Allow statements
    # and Deny exception on PrincipalArn.
    doc="$(jq -n \
      --arg bucket "$bucket" \
      --arg crr "$crr_role" \
      --arg bypass "$bypass" \
      --arg pub "$pub_role" \
      --arg lam "$lam_role" \
      --argjson vpces "$vpces_json" '
      def res: ["arn:aws:s3:::\($bucket)", "arn:aws:s3:::\($bucket)/*"];
      def exempt: [$bypass, $crr, $pub, $lam] | map(select(length > 0 and . != "null"));
      {
        Version: "2012-10-17",
        Statement: (
          [
            {
              Sid: "AllowAdminAndRoles",
              Effect: "Allow",
              Principal: {AWS: (if (exempt | length) == 1 then exempt[0] else exempt end)},
              Action: "s3:*",
              Resource: res
            },
            {
              Sid: "AllowSSLRequestsOnly",
              Effect: "Deny",
              Principal: "*",
              Action: "s3:*",
              Resource: res,
              Condition: {Bool: {"aws:SecureTransport": "false"}}
            }
          ]
          + (if ($vpces | length) > 0 then [
            {
              Sid: "DenyGetUnlessVpce",
              Effect: "Deny",
              Principal: "*",
              Action: ["s3:GetObject"],
              Resource: ["arn:aws:s3:::\($bucket)/*"],
              Condition: {
                StringNotEquals: {"aws:SourceVpce": $vpces},
                ArnNotEquals: {"aws:PrincipalArn": exempt}
              }
            },
            {
              Sid: "AllowVpceRead",
              Effect: "Allow",
              Principal: "*",
              Action: ["s3:GetObject", "s3:ListBucket"],
              Resource: res,
              Condition: {StringEquals: {"aws:SourceVpce": $vpces}}
            }
          ] else [] end)
        )
      }
    ')"
    run aws s3api put-bucket-policy --bucket "$bucket" --region "$region" --policy "$doc"
  }

  put_locked_pkg_policy "$primary" "$PRIMARY_REGION" "$syd_vpces"
  put_locked_pkg_policy "$replica" "$REPLICA_REGION" "$akl_vpces"
  printf 'allowlist applied to package buckets only (syd=%s akl=%s); UI bucket unchanged\n' \
    "$syd_vpces" "$akl_vpces" >&2
}

# Download sample packages; EventBridge Put of Packages/*.rpm / pool/*.deb
# triggers rebuild Lambda. Wait for indexes + catalog, then CRR.
cmd_publish() {
  require_env
  [[ -f "$STATE_FILE" ]] || die "missing state"
  command -v curl >/dev/null || die "curl not found"
  local primary replica ui_bucket lam_arn
  primary="$(state_get .primary_bucket)"
  replica="$(state_get .replica_bucket)"
  ui_bucket="$(state_get .ui_bucket)"
  lam_arn="$(state_get .rebuild_lambda_arn)"
  [[ -n "$lam_arn" && "$lam_arn" != "null" ]] || die "missing rebuild_lambda_arn; re-run up-shared with Docker"
  [[ -n "$ui_bucket" && "$ui_bucket" != "null" ]] || die "missing ui_bucket"
  export AWS_REGION="$PRIMARY_REGION" AWS_DEFAULT_REGION="$PRIMARY_REGION"

  local work
  work="$(mktemp -d)"
  # Expand path into trap now so RETURN under `set -u` does not see an unbound `work`.
  trap 'rm -rf "'"$work"'"' RETURN

  printf 'downloading sample packages...\n' >&2
  run curl -fsSL -o "$work/$SAMPLE_RPM_FILE" "$SAMPLE_RPM_URL"
  run curl -fsSL -o "$work/$SAMPLE_DEB_FILE" "$SAMPLE_DEB_URL"
  local rpm_sha deb_sha rpm_file deb_file
  rpm_file="$SAMPLE_RPM_FILE"
  deb_file="$SAMPLE_DEB_FILE"
  rpm_sha="$(sha256sum "$work/$rpm_file" | awk '{print $1}')"
  deb_sha="$(sha256sum "$work/$deb_file" | awk '{print $1}')"
  printf 'sample RPM sha256=%s\n' "$rpm_sha" >&2
  printf 'sample DEB sha256=%s\n' "$deb_sha" >&2

  local rpm_key deb_key
  rpm_key="${RPM_TREE}/Packages/${rpm_file}"
  deb_key="${DEB_TREE}/pool/main/h/hello/${deb_file}"

  # Prefer publisher role for package Puts when assumable.
  local pub_role_arn
  pub_role_arn="$(state_get .publisher_role_arn)"
  upload_pkg() {
    local src="$1" dst="$2"
    if [[ -n "$pub_role_arn" && "$pub_role_arn" != "null" ]]; then
      local creds
      if creds="$(aws sts assume-role --role-arn "$pub_role_arn" \
        --role-session-name demo-publish --duration-seconds 900 \
        --query 'Credentials' --output json 2>/dev/null)"; then
        printf 'using assumed publisher role for %s\n' "$dst" >&2
        AWS_ACCESS_KEY_ID="$(jq -r .AccessKeyId <<<"$creds")" \
        AWS_SECRET_ACCESS_KEY="$(jq -r .SecretAccessKey <<<"$creds")" \
        AWS_SESSION_TOKEN="$(jq -r .SessionToken <<<"$creds")" \
          aws s3 cp "$src" "$dst" --region "$PRIMARY_REGION"
        return 0
      fi
      printf 'warn: could not assume publisher role; uploading with caller credentials\n' >&2
    fi
    run aws s3 cp "$src" "$dst" --region "$PRIMARY_REGION"
  }

  local publish_started
  publish_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  upload_pkg "$work/$rpm_file" "s3://${primary}/${rpm_key}"
  upload_pkg "$work/$deb_file" "s3://${primary}/${deb_key}"
  printf '+ uploaded s3://%s/%s\n' "$primary" "$rpm_key" >&2
  printf '+ uploaded s3://%s/%s\n' "$primary" "$deb_key" >&2
  printf 'EventBridge → %s on Packages/*.rpm and pool/*.deb Put\n' "$lam_arn" >&2

  state_set_str '.packages.rpm_name' "$SAMPLE_RPM_NAME"
  state_set_str '.packages.deb_name' "$SAMPLE_DEB_NAME"
  state_set_str '.packages.rpm_key' "$rpm_key"
  state_set_str '.packages.deb_key' "$deb_key"
  state_set_str '.packages.rpm_file' "$rpm_file"
  state_set_str '.packages.deb_file' "$deb_file"
  state_set_str '.packages.rpm_sha256' "$rpm_sha"
  state_set_str '.packages.deb_sha256' "$deb_sha"

  # Wait for EventBridge-driven rebuild (indexes + fresh catalog with both packages).
  # Two Puts may fire two invokes; last write should include both packages.
  local i catalog_json catalog_count catalog_at
  printf 'waiting for EventBridge rebuild (indexes + catalog)...\n' >&2
  for i in $(seq 1 48); do
    catalog_json="$(aws s3 cp "s3://${ui_bucket}/catalog.json" - --region "$PRIMARY_REGION" 2>/dev/null || true)"
    catalog_count="$(jq -r '.packages|length // 0' <<<"$catalog_json" 2>/dev/null || echo 0)"
    catalog_at="$(jq -r '.generated_at // empty' <<<"$catalog_json" 2>/dev/null || true)"
    if aws s3api head-object --bucket "$primary" --region "$PRIMARY_REGION" \
         --key "${RPM_TREE}/repodata/repomd.xml" >/dev/null 2>&1 \
       && aws s3api head-object --bucket "$primary" --region "$PRIMARY_REGION" \
            --key "${RPM_TREE}/repodata/repomd.xml.asc" >/dev/null 2>&1 \
       && aws s3api head-object --bucket "$primary" --region "$PRIMARY_REGION" \
            --key "${DEB_TREE}/dists/noble/Release" >/dev/null 2>&1 \
       && aws s3api head-object --bucket "$primary" --region "$PRIMARY_REGION" \
            --key "${DEB_TREE}/dists/noble/InRelease" >/dev/null 2>&1 \
       && [[ "${catalog_count:-0}" -ge 2 ]] \
       && [[ -n "$catalog_at" && ! "$catalog_at" < "$publish_started" ]]; then
      printf 'indexes + signatures + catalog present on primary (packages=%s generated_at=%s)\n' \
        "$catalog_count" "$catalog_at" >&2
      break
    fi
    sleep 5
    [[ "$i" -eq 48 ]] && die "timeout waiting for EventBridge rebuild; check rule ${NAME_PREFIX}-pkg-put-* and Lambda logs"
  done

  printf 'waiting for CRR of package + index keys to %s ...\n' "$replica" >&2
  for i in $(seq 1 48); do
    if aws s3api head-object --bucket "$replica" --key "$rpm_key" --region "$REPLICA_REGION" >/dev/null 2>&1 \
       && aws s3api head-object --bucket "$replica" --key "$deb_key" --region "$REPLICA_REGION" >/dev/null 2>&1 \
       && aws s3api head-object --bucket "$replica" --region "$REPLICA_REGION" \
            --key "${RPM_TREE}/repodata/repomd.xml" >/dev/null 2>&1 \
       && aws s3api head-object --bucket "$replica" --region "$REPLICA_REGION" \
            --key "${RPM_TREE}/repodata/repomd.xml.asc" >/dev/null 2>&1 \
       && aws s3api head-object --bucket "$replica" --region "$REPLICA_REGION" \
            --key "${DEB_TREE}/dists/noble/Release" >/dev/null 2>&1 \
       && aws s3api head-object --bucket "$replica" --region "$REPLICA_REGION" \
            --key "${DEB_TREE}/dists/noble/InRelease" >/dev/null 2>&1; then
      printf 'packages + indexes + signatures replicated to replica\n' >&2
      printf 'publish complete\n' >&2
      return 0
    fi
    sleep 5
  done
  die "CRR timeout for package/index keys"
}

cmd_open_ui() {
  require_env
  [[ -f "$STATE_FILE" ]] || die "missing state"
  local url bucket
  url="$(state_get .ui_website_url)"
  bucket="$(state_get .ui_bucket)"
  if [[ -z "$url" || "$url" == "null" ]]; then
    [[ -n "$bucket" && "$bucket" != "null" ]] || die "no ui_bucket; run up-shared first"
    url="http://${bucket}.s3-website-${PRIMARY_REGION}.amazonaws.com"
  fi
  printf '%s\n' "$url"
}

ssm_wait_success() {
  local cmd_id="$1" iid="$2" region="$3" label="$4"
  local i status
  for i in $(seq 1 40); do
    sleep 3
    status="$(aws ssm get-command-invocation \
      --command-id "$cmd_id" \
      --instance-id "$iid" \
      --region "$region" \
      --query 'Status' --output text 2>/dev/null || echo Pending)"
    case "$status" in
      Success) return 0 ;;
      Failed|Cancelled|TimedOut)
        run aws ssm get-command-invocation \
          --command-id "$cmd_id" --instance-id "$iid" --region "$region" \
          --query '{Status:Status,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
          --output json
        die "prove $label failed: SSM status=$status"
        ;;
    esac
  done
  die "prove $label timed out waiting for SSM"
}

cmd_prove() {
  require_env
  local which="${1:-}"
  [[ "$which" == "syd" || "$which" == "akl" ]] || die "prove requires syd|akl"
  [[ -f "$STATE_FILE" ]] || die "missing state"

  local region bucket rpm_name deb_name iid_al iid_ub base_url
  region="$(jq -r --arg w "$which" '.consumers[$w].region // empty' "$STATE_FILE")"
  bucket="$(jq -r --arg w "$which" '.consumers[$w].bucket // empty' "$STATE_FILE")"
  iid_al="$(jq -r --arg w "$which" '.consumers[$w].al2023.instance_id // empty' "$STATE_FILE")"
  iid_ub="$(jq -r --arg w "$which" '.consumers[$w].ubuntu.instance_id // empty' "$STATE_FILE")"
  rpm_name="$(state_get .packages.rpm_name)"
  deb_name="$(state_get .packages.deb_name)"
  [[ -n "$rpm_name" && "$rpm_name" != "null" ]] || die "missing packages; run publish first"
  [[ -n "$iid_al" && -n "$iid_ub" && -n "$region" && -n "$bucket" ]] || \
    die "missing consumer $which; run up-consumer $which first"

  export AWS_REGION="$region" AWS_DEFAULT_REGION="$region"
  base_url="https://${bucket}.s3.${region}.amazonaws.com"

  # --- AL2023: dnf (repo metadata GPG; package gpgcheck off for sample EPEL RPM) ---
  local repo_cmd cmd_id pubkey_url
  pubkey_url="${base_url}/repos/gpg/lab-signing.asc"
  repo_cmd=$(cat <<EOF
set -eux
printf '=== lab public key ===\n'
curl -fsSL -o /etc/pki/rpm-gpg/RPM-GPG-KEY-ps3p-lab '${pubkey_url}'
gpg --batch --show-keys --with-fingerprint /etc/pki/rpm-gpg/RPM-GPG-KEY-ps3p-lab
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-ps3p-lab
rpm -q gpg-pubkey --qf '%{NAME}-%{VERSION}-%{RELEASE}\t%{SUMMARY}\n' | grep -F 'private-s3-pkg-repo lab' || true
cat >/etc/yum.repos.d/ps3p-lab.repo <<'REPO'
[ps3p-lab]
name=private-s3-pkg-repo lab
baseurl=${base_url}/${RPM_TREE}
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-ps3p-lab
REPO
printf '=== repo file ===\n'
cat /etc/yum.repos.d/ps3p-lab.repo
printf '=== gpg --verify repomd.xml.asc ===\n'
curl -fsSL -o /tmp/repomd.xml '${base_url}/${RPM_TREE}/repodata/repomd.xml'
curl -fsSL -o /tmp/repomd.xml.asc '${base_url}/${RPM_TREE}/repodata/repomd.xml.asc'
gpg --batch --import /etc/pki/rpm-gpg/RPM-GPG-KEY-ps3p-lab >/tmp/gpg-import.log 2>&1 || true
cat /tmp/gpg-import.log
gpg --batch --status-fd 1 --verify /tmp/repomd.xml.asc /tmp/repomd.xml > /tmp/gpg-verify.log 2>&1 || true
cat /tmp/gpg-verify.log
grep -F 'GOODSIG' /tmp/gpg-verify.log
dnf -y remove ${rpm_name} 2>/dev/null || true
dnf -y clean all
printf '=== dnf install (repo_gpgcheck=1) ===\n'
dnf -y --disablerepo='*' --enablerepo=ps3p-lab install ${rpm_name}
rpm -q ${rpm_name}
EOF
)
  cmd_id="$(run aws ssm send-command \
    --instance-ids "$iid_al" \
    --document-name AWS-RunShellScript \
    --region "$region" \
    --parameters "$(jq -n --arg c "$repo_cmd" '{commands:[$c]}')" \
    --query 'Command.CommandId' --output text)"
  ssm_wait_success "$cmd_id" "$iid_al" "$region" "${which}/al2023"
  run aws ssm get-command-invocation \
    --command-id "$cmd_id" --instance-id "$iid_al" --region "$region" \
    --query '{Status:Status,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
    --output json

  # --- Ubuntu: apt (signed-by lab key; only lab list — no NAT for archive.ubuntu.com) ---
  local apt_cmd
  apt_cmd=$(cat <<EOF
set -eux
mkdir -p /etc/apt/keyrings /etc/apt/sources.list.d
rm -f /etc/apt/sources.list
printf '=== lab public key ===\n'
curl -fsSL '${pubkey_url}' -o /tmp/ps3p-lab.asc
gpg --batch --show-keys --with-fingerprint /tmp/ps3p-lab.asc
gpg --batch --yes --dearmor -o /etc/apt/keyrings/ps3p-lab.gpg /tmp/ps3p-lab.asc
chmod 644 /etc/apt/keyrings/ps3p-lab.gpg
echo 'deb [signed-by=/etc/apt/keyrings/ps3p-lab.gpg] ${base_url}/${DEB_TREE} noble main' > /etc/apt/sources.list.d/ps3p-lab.list
printf '=== sources.list ===\n'
cat /etc/apt/sources.list.d/ps3p-lab.list
printf '=== gpg --verify InRelease ===\n'
curl -fsSL -o /tmp/InRelease '${base_url}/${DEB_TREE}/dists/noble/InRelease'
gpg --batch --import /tmp/ps3p-lab.asc >/tmp/gpg-import.log 2>&1 || true
cat /tmp/gpg-import.log
gpg --batch --status-fd 1 --verify /tmp/InRelease > /tmp/gpg-verify.log 2>&1 || true
cat /tmp/gpg-verify.log
grep -F 'GOODSIG' /tmp/gpg-verify.log
apt-get remove -y ${deb_name} 2>/dev/null || true
printf '=== apt-get update (InRelease / gpgv) ===\n'
apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/ps3p-lab.list \
  -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 \
  -o Debug::Acquire::gpgv=1
printf '=== apt-get install ===\n'
apt-get install -y ${deb_name}
apt-cache policy ${deb_name}
dpkg -l ${deb_name}
EOF
)
  cmd_id="$(run aws ssm send-command \
    --instance-ids "$iid_ub" \
    --document-name AWS-RunShellScript \
    --region "$region" \
    --parameters "$(jq -n --arg c "$apt_cmd" '{commands:[$c]}')" \
    --query 'Command.CommandId' --output text)"
  ssm_wait_success "$cmd_id" "$iid_ub" "$region" "${which}/ubuntu"
  run aws ssm get-command-invocation \
    --command-id "$cmd_id" --instance-id "$iid_ub" --region "$region" \
    --query '{Status:Status,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
    --output json

  printf 'prove %s: al2023 + ubuntu Success\n' "$which" >&2
}

# Returns 0 if AWS call succeeded or the resource is already gone.
# Auth/token failures abort the whole process so state is preserved.
# Other failures increment DOWN_FAILS (caller must declare it).
down_aws() {
  local out rc
  printf '+ %s\n' "$*" >&2
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  [[ -n "$out" ]] && printf '%s\n' "$out" >&2
  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi
  if grep -qiE \
    'ExpiredToken|UnauthorizedSSOTokenLoad|TokenRefreshRequired|InvalidClientTokenId|RequestExpired|Unable to locate credentials|Error when retrieving token' \
    <<<"$out"; then
    die "AWS auth failed mid-teardown. State kept at ${STATE_FILE} — re-login and re-run: ./scripts/demo.sh down"
  fi
  if grep -qiE \
    'ResourceNotFound|NoSuchBucket|NoSuchEntity|NoSuchKey|NoSuchLifecycleConfiguration|ReplicationConfigurationNotFound|RepositoryNotFoundException|InvalidVpcID|InvalidGroup\.NotFound|InvalidGroupId|InvalidInstanceID|InvalidRouteTableID\.NotFound|InvalidSubnetID\.NotFound|InvalidVpcEndpointId|InvalidPermission\.NotFound|404|NotFound|does not exist|not found' \
    <<<"$out"; then
    return 0
  fi
  DOWN_FAILS=$((DOWN_FAILS + 1))
  printf 'warn: teardown step failed (%s)\n' "$*" >&2
  return 0
}

empty_bucket() {
  local bucket="$1" region="$2"
  printf 'emptying %s (%s)\n' "$bucket" "$region" >&2
  local page objs n del chunk rounds=0
  del="$(mktemp)"
  # Re-list until empty (versioned buckets; list-object-versions is paginated).
  while true; do
    rounds=$((rounds + 1))
    [[ "$rounds" -le 100 ]] || die "empty_bucket: still not empty after ${rounds} rounds: ${bucket}"
    set +e
    page="$(aws s3api list-object-versions --bucket "$bucket" --region "$region" --max-keys 1000 --output json 2>&1)"
    local list_rc=$?
    set -e
    if [[ "$list_rc" -ne 0 ]]; then
      if grep -qiE 'NoSuchBucket|404|Not Found' <<<"$page"; then
        rm -f "$del"
        return 0
      fi
      if grep -qiE \
        'ExpiredToken|UnauthorizedSSOTokenLoad|TokenRefreshRequired|InvalidClientTokenId|RequestExpired|Unable to locate credentials|Error when retrieving token' \
        <<<"$page"; then
        rm -f "$del"
        die "AWS auth failed while emptying ${bucket}. State kept at ${STATE_FILE}"
      fi
      printf '%s\n' "$page" >&2
      DOWN_FAILS=$((DOWN_FAILS + 1))
      rm -f "$del"
      return 0
    fi
    objs="$(jq -c '
      [(.Versions // [])[] | {Key, VersionId}]
      + [(.DeleteMarkers // [])[] | {Key, VersionId}]
    ' <<<"$page")"
    n="$(jq 'length' <<<"$objs")"
    [[ "$n" -gt 0 ]] || break
    chunk="$(jq -c '{Objects: ., Quiet: true}' <<<"$objs")"
    printf '%s\n' "$chunk" >"$del"
    down_aws aws s3api delete-objects --bucket "$bucket" --region "$region" --delete "file://${del}"
  done
  rm -f "$del"
}

cmd_down() {
  require_env
  local STATE_BAK="${STATE_FILE}.bak"
  if [[ ! -f "$STATE_FILE" ]]; then
    if [[ -f "$STATE_BAK" ]]; then
      printf 'restoring %s from backup\n' "$STATE_FILE" >&2
      cp -f "$STATE_BAK" "$STATE_FILE"
    else
      die "nothing to tear down"
    fi
  fi
  printf 'Destroy lab resources described in %s? [y/N] ' "$STATE_FILE" >&2
  read -r ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || die "aborted"

  # Fail fast before deleting anything; keep a backup so a mid-run abort is recoverable.
  account_id >/dev/null || die "AWS auth check failed; refresh credentials and retry"
  cp -f "$STATE_FILE" "$STATE_BAK"
  printf 'state backup: %s\n' "$STATE_BAK" >&2

  # Global so down_aws / empty_bucket (top-level) can increment it.
  DOWN_FAILS=0

  wait_vpce_gone() {
    local region="$1" vid="$2" i state
    [[ -n "$vid" ]] || return 0
    for i in $(seq 1 36); do
      state="$(aws ec2 describe-vpc-endpoints --region "$region" --vpc-endpoint-ids "$vid" \
        --query 'VpcEndpoints[0].State' --output text 2>/dev/null || echo gone)"
      [[ "$state" == "gone" || "$state" == "None" || -z "$state" ]] && return 0
      sleep 5
    done
    printf 'warn: VPCE %s still %s in %s\n' "$vid" "$state" "$region" >&2
    DOWN_FAILS=$((DOWN_FAILS + 1))
  }

  # --- Lambda / EventBridge / ECR (if present) ---
  export AWS_REGION="$PRIMARY_REGION" AWS_DEFAULT_REGION="$PRIMARY_REGION"
  local lam_arn rule_name ecr_repo
  lam_arn="$(state_get .rebuild_lambda_arn)"
  rule_name="$(state_get .eventbridge_rule_name)"
  ecr_repo="$(jq -r '.ecr_repository // empty' "$STATE_FILE")"
  if [[ -n "$rule_name" && "$rule_name" != "null" ]]; then
    down_aws aws events remove-targets --region "$PRIMARY_REGION" --rule "$rule_name" --ids "1"
    down_aws aws events delete-rule --region "$PRIMARY_REGION" --name "$rule_name"
  fi
  if [[ -n "$lam_arn" && "$lam_arn" != "null" && "$lam_arn" != "" ]]; then
    down_aws aws lambda delete-function --region "$PRIMARY_REGION" --function-name "$lam_arn"
  fi
  if [[ -n "$ecr_repo" && "$ecr_repo" != "null" ]]; then
    down_aws aws ecr delete-repository --region "$PRIMARY_REGION" --repository-name "$ecr_repo" --force
  fi

  # --- UI bucket ---
  local ui_bucket
  ui_bucket="$(state_get .ui_bucket)"
  if [[ -n "$ui_bucket" && "$ui_bucket" != "null" ]]; then
    empty_bucket "$ui_bucket" "$PRIMARY_REGION"
    down_aws aws s3api delete-bucket --bucket "$ui_bucket" --region "$PRIMARY_REGION"
  fi

  # --- Consumers (both instances per region) ---
  for which in syd akl; do
    local region role sg_ec2 sg_ssm created created_vpc vpc subnet rtb
    region="$(jq -r --arg w "$which" '.consumers[$w].region // empty' "$STATE_FILE")"
    [[ -n "$region" && "$region" != "null" ]] || continue
    role="$(jq -r --arg w "$which" '.consumers[$w].role_name // empty' "$STATE_FILE")"
    sg_ec2="$(jq -r --arg w "$which" '.consumers[$w].sg_ec2 // empty' "$STATE_FILE")"
    sg_ssm="$(jq -r --arg w "$which" '.consumers[$w].sg_ssm // empty' "$STATE_FILE")"
    created="$(jq -r --arg w "$which" '.consumers[$w].created_s3_vpce // false' "$STATE_FILE")"
    created_vpc="$(jq -r --arg w "$which" '.consumers[$w].created_vpc // false' "$STATE_FILE")"
    vpc="$(jq -r --arg w "$which" '.consumers[$w].vpc_id // empty' "$STATE_FILE")"
    subnet="$(jq -r --arg w "$which" '.consumers[$w].subnet_id // empty' "$STATE_FILE")"
    rtb="$(jq -r --arg w "$which" '.consumers[$w].route_table_id // empty' "$STATE_FILE")"
    export AWS_REGION="$region" AWS_DEFAULT_REGION="$region"
    printf 'tearing down consumer %s in %s\n' "$which" "$region" >&2

    local iids=()
    local iid
    for os in al2023 ubuntu; do
      iid="$(jq -r --arg w "$which" --arg os "$os" '.consumers[$w][$os].instance_id // empty' "$STATE_FILE")"
      [[ -n "$iid" ]] && iids+=("$iid")
    done
    # Legacy single-instance shape
    iid="$(jq -r --arg w "$which" '.consumers[$w].instance_id // empty' "$STATE_FILE")"
    [[ -n "$iid" ]] && iids+=("$iid")

    if [[ ${#iids[@]} -gt 0 ]]; then
      down_aws aws ec2 terminate-instances --region "$region" --instance-ids "${iids[@]}"
      down_aws aws ec2 wait instance-terminated --region "$region" --instance-ids "${iids[@]}"
    fi

    local vids=()
    while read -r vid; do
      [[ -n "$vid" ]] || continue
      vids+=("$vid")
      down_aws aws ec2 delete-vpc-endpoints --region "$region" --vpc-endpoint-ids "$vid"
    done < <(jq -r --arg w "$which" '.consumers[$w].ssm_vpce_ids[]?' "$STATE_FILE")
    if [[ "$created" == "true" ]]; then
      local sv
      sv="$(jq -r --arg w "$which" '(.consumers[$w].gateway_vpce_id // .consumers[$w].s3_vpce_id // "")' "$STATE_FILE")"
      if [[ -n "$sv" ]]; then
        vids+=("$sv")
        down_aws aws ec2 delete-vpc-endpoints --region "$region" --vpc-endpoint-ids "$sv"
      fi
    fi
    for vid in "${vids[@]}"; do
      wait_vpce_gone "$region" "$vid"
    done

    [[ -n "$sg_ec2" ]] && down_aws aws ec2 delete-security-group --region "$region" --group-id "$sg_ec2"
    [[ -n "$sg_ssm" ]] && down_aws aws ec2 delete-security-group --region "$region" --group-id "$sg_ssm"
    if [[ -n "$role" ]]; then
      down_aws aws iam remove-role-from-instance-profile --instance-profile-name "$role" --role-name "$role"
      down_aws aws iam delete-instance-profile --instance-profile-name "$role"
      down_aws aws iam delete-role-policy --role-name "$role" --policy-name package-read
      down_aws aws iam delete-role-policy --role-name "$role" --policy-name artifact-read
      down_aws aws iam detach-role-policy --role-name "$role" \
        --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
      down_aws aws iam delete-role --role-name "$role"
    fi

    if [[ "$created_vpc" == "true" ]]; then
      if [[ -n "$rtb" ]]; then
        while read -r assoc; do
          [[ -n "$assoc" && "$assoc" != "None" ]] && \
            down_aws aws ec2 disassociate-route-table --region "$region" --association-id "$assoc"
        done < <(aws ec2 describe-route-tables --region "$region" --route-table-ids "$rtb" \
          --query 'RouteTables[0].Associations[?SubnetId!=null].RouteTableAssociationId' \
          --output text 2>/dev/null | tr '\t' '\n')
      fi
      local i
      for i in 1 2 3 4 5 6; do
        if [[ -n "$subnet" ]]; then
          down_aws aws ec2 delete-subnet --region "$region" --subnet-id "$subnet"
          if ! aws ec2 describe-subnets --region "$region" --subnet-ids "$subnet" >/dev/null 2>&1; then
            subnet=""
          fi
        fi
        if [[ -n "$rtb" ]]; then
          down_aws aws ec2 delete-route-table --region "$region" --route-table-id "$rtb"
          if ! aws ec2 describe-route-tables --region "$region" --route-table-ids "$rtb" >/dev/null 2>&1; then
            rtb=""
          fi
        fi
        if [[ -n "$vpc" ]]; then
          down_aws aws ec2 delete-vpc --region "$region" --vpc-id "$vpc"
          if ! aws ec2 describe-vpcs --region "$region" --vpc-ids "$vpc" >/dev/null 2>&1; then
            vpc=""
          fi
        fi
        [[ -z "$subnet" && -z "$rtb" && -z "$vpc" ]] && break
        sleep 5
      done
      if [[ -n "$vpc" ]]; then
        printf 'warn: VPC %s may still exist in %s\n' "$vpc" "$region" >&2
        DOWN_FAILS=$((DOWN_FAILS + 1))
      fi
    fi
  done

  # --- Secrets Manager GPG key ---
  local gpg_secret
  gpg_secret="$(jq -r '.gpg_secret_arn // .gpg_secret_name // empty' "$STATE_FILE")"
  if [[ -n "$gpg_secret" && "$gpg_secret" != "null" ]]; then
    down_aws aws secretsmanager delete-secret --region "$PRIMARY_REGION" \
      --secret-id "$gpg_secret" --force-delete-without-recovery
  fi

  # --- Package buckets + IAM roles ---
  local primary replica crr_arn pub_arn lam_role_arn role_name
  primary="$(state_get .primary_bucket)"
  replica="$(state_get .replica_bucket)"
  crr_arn="$(state_get .crr_role_arn)"
  pub_arn="$(state_get .publisher_role_arn)"
  lam_role_arn="$(state_get .rebuild_lambda_role_arn)"
  [[ "$primary" == "null" ]] && primary=""
  [[ "$replica" == "null" ]] && replica=""
  export AWS_REGION="$PRIMARY_REGION" AWS_DEFAULT_REGION="$PRIMARY_REGION"
  if [[ -n "$primary" ]]; then
    down_aws aws s3api delete-bucket-replication --bucket "$primary" --region "$PRIMARY_REGION"
    empty_bucket "$primary" "$PRIMARY_REGION"
    down_aws aws s3api delete-bucket --bucket "$primary" --region "$PRIMARY_REGION"
  fi
  if [[ -n "$replica" ]]; then
    empty_bucket "$replica" "$REPLICA_REGION"
    down_aws aws s3api delete-bucket --bucket "$replica" --region "$REPLICA_REGION"
  fi

  for arn in "$crr_arn" "$pub_arn" "$lam_role_arn"; do
    [[ -n "$arn" && "$arn" != "null" ]] || continue
    role_name="${arn##*/}"
    case "$arn" in
      *crr*) down_aws aws iam delete-role-policy --role-name "$role_name" --policy-name crr ;;
      *publisher*) down_aws aws iam delete-role-policy --role-name "$role_name" --policy-name publisher ;;
      *rebuild*)
        down_aws aws iam delete-role-policy --role-name "$role_name" --policy-name rebuild
        down_aws aws iam detach-role-policy --role-name "$role_name" \
          --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
        ;;
    esac
    down_aws aws iam delete-role --role-name "$role_name"
  done

  # Post-check: refuse to clear state while key resources still exist.
  local still=0
  resource_still() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
      printf 'still present: %s\n' "$label" >&2
      still=$((still + 1))
    fi
  }
  [[ -n "$ui_bucket" && "$ui_bucket" != "null" ]] && \
    resource_still "ui bucket $ui_bucket" aws s3api head-bucket --bucket "$ui_bucket" --region "$PRIMARY_REGION"
  [[ -n "$primary" ]] && \
    resource_still "primary bucket $primary" aws s3api head-bucket --bucket "$primary" --region "$PRIMARY_REGION"
  [[ -n "$replica" ]] && \
    resource_still "replica bucket $replica" aws s3api head-bucket --bucket "$replica" --region "$REPLICA_REGION"
  if [[ -n "$lam_arn" && "$lam_arn" != "null" && "$lam_arn" != "" ]]; then
    resource_still "lambda $lam_arn" aws lambda get-function --region "$PRIMARY_REGION" --function-name "$lam_arn"
  fi
  if [[ -n "$gpg_secret" && "$gpg_secret" != "null" ]]; then
    # Force-delete can still describe briefly with DeletedDate set — treat as gone.
    set +e
    gpg_meta="$(aws secretsmanager describe-secret --region "$PRIMARY_REGION" \
      --secret-id "$gpg_secret" --output json 2>&1)"
    gpg_rc=$?
    set -e
    if [[ "$gpg_rc" -eq 0 ]]; then
      if ! jq -e '(.DeletedDate // .DeletionDate) != null' <<<"$gpg_meta" >/dev/null 2>&1; then
        printf 'still present: gpg secret %s\n' "$gpg_secret" >&2
        still=$((still + 1))
      fi
    fi
  fi
  for which in syd akl; do
    vpc="$(jq -r --arg w "$which" '.consumers[$w].vpc_id // empty' "$STATE_FILE")"
    region="$(jq -r --arg w "$which" '.consumers[$w].region // empty' "$STATE_FILE")"
    created_vpc="$(jq -r --arg w "$which" '.consumers[$w].created_vpc // false' "$STATE_FILE")"
    if [[ "$created_vpc" == "true" && -n "$vpc" && -n "$region" ]]; then
      resource_still "vpc $vpc ($which)" aws ec2 describe-vpcs --region "$region" --vpc-ids "$vpc"
    fi
  done

  if [[ "$DOWN_FAILS" -gt 0 || "$still" -gt 0 ]]; then
    die "teardown incomplete (step failures=${DOWN_FAILS}, still present=${still}). State kept at ${STATE_FILE} (backup ${STATE_BAK}). Fix and re-run: ./scripts/demo.sh down"
  fi

  rm -f "$STATE_FILE" "$STATE_BAK"
  printf 'down complete\n' >&2
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    up-shared) cmd_up_shared "$@" ;;
    up-consumer) cmd_up_consumer "$@" ;;
    allowlist) cmd_allowlist "$@" ;;
    publish) cmd_publish "$@" ;;
    open-ui) cmd_open_ui "$@" ;;
    prove) cmd_prove "$@" ;;
    status) cmd_status "$@" ;;
    down) cmd_down "$@" ;;
    -h|--help|help|"") usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
