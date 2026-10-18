#!/usr/bin/env bash
#
# Starting point for a static site host. Copy it into your repository, commit
# it, and point `source.bootstrap` at it. Edit it freely: mov runs whatever is
# in your repository, never this copy.
#
# cloud-init clones the repository to $MOV_APP_DIR on first boot and runs this
# as root. Nothing is hardcoded here; everything comes from /etc/mov/deploy.env,
# which cloud-init writes from the deployment profile:
#
#   MOV_ENV       the environment that produced this host
#   MOV_REPO      owner/name of the repository that was cloned
#   MOV_REF       the branch or tag that was cloned
#   MOV_PATH      directory inside the repo to serve, relative to MOV_APP_DIR
#   MOV_APP_DIR   where the repository was cloned
#
# Packages listed under host.packages in the profile are already installed.
#
# Safe to re-run: `mov up` on an existing environment runs it again, and that is
# how a redeploy picks up a change.

set -euo pipefail

readonly ENV_FILE=/etc/mov/deploy.env
readonly DOCROOT=/var/www/mov
readonly SITE=mov
readonly STAMP=/etc/mov/deployed.json

log() { printf '[bootstrap] %s\n' "$*"; }
fail() { printf '[bootstrap] error: %s\n' "$*" >&2; exit 1; }

# --- configuration ----------------------------------------------------------

[[ -r $ENV_FILE ]] || fail "$ENV_FILE is missing. cloud-init writes it; this script cannot run standalone."
# shellcheck disable=SC1090
source "$ENV_FILE"

for var in MOV_ENV MOV_REPO MOV_REF MOV_PATH MOV_APP_DIR; do
    [[ -n ${!var:-} ]] || fail "$var is not set in $ENV_FILE"
done

readonly SOURCE_DIR="${MOV_APP_DIR%/}/${MOV_PATH#/}"
[[ -d $SOURCE_DIR ]] || fail "$SOURCE_DIR does not exist. Check source.path in the profile."
[[ -f $SOURCE_DIR/index.html ]] || fail "$SOURCE_DIR has no index.html."

log "env=$MOV_ENV repo=$MOV_REPO ref=$MOV_REF serving=$SOURCE_DIR"

# --- nginx ------------------------------------------------------------------

# cloud-init installs it on first boot. This covers a manual re-run, with the
# package manager the image has: apt on Debian and Ubuntu, dnf on Amazon Linux
# 2023 and the RHEL family, yum where there is no dnf. Asked by command, not
# by the distribution's name.
if ! command -v nginx >/dev/null 2>&1; then
    log "installing nginx"
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq nginx
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q nginx
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q nginx
    else
        fail "no apt-get, dnf or yum here to install nginx with"
    fi
fi

# The user nginx serves as: www-data on Debian and Ubuntu, nginx on the dnf family.
WEB_USER=www-data
id -u "$WEB_USER" >/dev/null 2>&1 || WEB_USER=nginx

# Where a server block goes: sites-available, linked from sites-enabled, on
# Debian and Ubuntu; conf.d on the dnf family, whose nginx has no sites folders.
if [[ -d /etc/nginx/sites-available ]]; then
    CONF="/etc/nginx/sites-available/$SITE"
else
    CONF="/etc/nginx/conf.d/$SITE.conf"
fi

# --- content ----------------------------------------------------------------

# Replace rather than merge, so a file deleted in the repository also disappears
# from the host.
install -d -m 0755 "$DOCROOT"
find "$DOCROOT" -mindepth 1 -delete
cp -a "$SOURCE_DIR/." "$DOCROOT/"
chown -R "$WEB_USER:$WEB_USER" "$DOCROOT"
find "$DOCROOT" -type d -exec chmod 0755 {} +
find "$DOCROOT" -type f -exec chmod 0644 {} +

log "deployed $(find "$DOCROOT" -type f | wc -l) file(s) to $DOCROOT"

# --- server block -----------------------------------------------------------

cat > "$CONF" <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root $DOCROOT;
    index index.html;

    server_name _;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Dotfiles are not served.
    location ~ /\. {
        deny all;
    }
}
NGINX

if [[ -d /etc/nginx/sites-available ]]; then
    ln -sfn "$CONF" "/etc/nginx/sites-enabled/$SITE"
    rm -f /etc/nginx/sites-enabled/default
fi

nginx -t
systemctl enable --now nginx
systemctl reload nginx

# --- record what is actually running ----------------------------------------

install -d -m 0755 "$(dirname "$STAMP")"
cat > "$STAMP" <<JSON
{
  "env": "$MOV_ENV",
  "repo": "$MOV_REPO",
  "ref": "$MOV_REF",
  "path": "$MOV_PATH",
  "commit": "$(git -C "$MOV_APP_DIR" rev-parse HEAD 2>/dev/null || echo unknown)",
  "deployedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

log "done. $(tr -d '\n ' < "$STAMP")"
