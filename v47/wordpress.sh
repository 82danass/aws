#!/usr/bin/env bash
#
# WordPress on Amazon Linux 2023, on each server the Auto Scaling group starts
# behind the load balancer, with the database in RDS, the files on EFS and a
# daily dump of the database in S3.
#
# The launch template's cloud-init clones the repository to $MOV_APP_DIR on
# first boot and runs this as root. Nothing is hardcoded here; everything comes
# from /etc/mov/deploy.env, which cloud-init writes from the profile:
#
#   MOV_ENV        the environment that produced this server
#   MOV_APP_DIR    where the repository was cloned
#   DB_HOST        the RDS instance's address, private to the VPC
#   DB_NAME        the database WordPress uses
#   DB_SECRET      the Secrets Manager secret RDS keeps the master user in
#   EFS_ID         the EFS file system WordPress's files live on
#   BACKUP_BUCKET  the S3 bucket the database dumps go to
#   SITE_URL       the load balancer's address, which is WordPress's own
#
# The region comes from the instance's metadata. The instance's role may read
# the secret and write the dumps, nothing else.
#
# Every server runs this, often two at the same moment. WordPress is
# downloaded and installed under a lock on EFS by the first; the others wait
# for the lock and find it there. One dump a day is made, by whichever server
# comes first.

set -euo pipefail

readonly ENV_FILE=/etc/mov/deploy.env
readonly DOCROOT=/var/www/html
readonly STAMP=/etc/mov/deployed.json
readonly WP=/usr/local/bin/wp

log() { printf '[wordpress] %s\n' "$*"; }
fail() { printf '[wordpress] error: %s\n' "$*" >&2; exit 1; }

# --- configuration ----------------------------------------------------------

[[ -r $ENV_FILE ]] || fail "$ENV_FILE is missing. cloud-init writes it; this script cannot run standalone."
# shellcheck disable=SC1090
source "$ENV_FILE"

for var in MOV_ENV MOV_REPO MOV_REF MOV_APP_DIR DB_HOST DB_NAME DB_SECRET EFS_ID BACKUP_BUCKET SITE_URL; do
    [[ -n ${!var:-} ]] || fail "$var is not set in $ENV_FILE"
done

TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
meta() { curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }
REGION=$(meta placement/region)
ZONE=$(meta placement/availability-zone)
PRIVATE_IP=$(meta local-ipv4)
export AWS_DEFAULT_REGION=$REGION

log "env=$MOV_ENV zone=$ZONE server=$PRIVATE_IP db=$DB_HOST efs=$EFS_ID bucket=$BACKUP_BUCKET site=$SITE_URL"

# --- packages ---------------------------------------------------------------

# The packages AWS's own WordPress tutorial for Amazon Linux 2023 uses, with
# the MariaDB client for the dumps and nfs-utils for EFS.
log "installing httpd, php, the mariadb client and nfs-utils"
dnf install -y -q httpd php php-fpm php-mysqli php-mysqlnd php-json mariadb105 nfs-utils

# --- shared storage ---------------------------------------------------------

# EFS over NFS 4.1 with the options AWS gives. noresvport takes the client's
# port from 1024-65535, the range the NACLs let the replies back on. Each
# server reaches the mount target in its own zone.
readonly EFS_DNS="$EFS_ID.efs.$REGION.amazonaws.com"
readonly MOUNT_OPTIONS=nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,_netdev
install -d -m 0755 "$DOCROOT"
grep -q " $DOCROOT nfs4 " /etc/fstab || echo "$EFS_DNS:/ $DOCROOT nfs4 $MOUNT_OPTIONS 0 0" >> /etc/fstab
for attempt in $(seq 1 30); do
    mountpoint -q "$DOCROOT" && break
    mount "$DOCROOT" && break
    log "EFS does not answer yet ($attempt/30)"
    sleep 10
done
mountpoint -q "$DOCROOT" || fail "could not mount $EFS_DNS on $DOCROOT"
log "EFS $EFS_ID mounted on $DOCROOT"

# --- the database's user ----------------------------------------------------

# RDS keeps the master user and its password in Secrets Manager.
SECRET=""
for attempt in $(seq 1 30); do
    SECRET=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET" --query SecretString --output text 2>/dev/null) && break
    log "the secret cannot be read yet ($attempt/30)"
    sleep 10
done
[[ -n $SECRET ]] || fail "could not read $DB_SECRET"
DB_USER=$(python3 -c 'import json, sys; print(json.load(sys.stdin)["username"])' <<<"$SECRET")
DB_PASSWORD=$(python3 -c 'import json, sys; print(json.load(sys.stdin)["password"])' <<<"$SECRET")

# --- WordPress --------------------------------------------------------------

if [[ ! -x $WP ]]; then
    log "installing wp-cli"
    curl -sfL -o "$WP" https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod 0755 "$WP"
fi
# Unpacking WordPress takes more than PHP's 128 MB default.
wp() { php -d memory_limit=512M "$WP" --path="$DOCROOT" --allow-root "$@"; }

# The servers share EFS and start together: the first takes the lock and
# installs, the others wait for it and find WordPress there.
exec 9>"$DOCROOT/.mov-install.lock"
log "waiting for the install lock on EFS"
flock 9
if [[ ! -f $DOCROOT/wp-includes/version.php ]]; then
    log "downloading WordPress to $DOCROOT"
    wp core download --locale=sv_SE
fi
if [[ ! -f $DOCROOT/wp-config.php ]]; then
    wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost="$DB_HOST" --skip-check
fi
# RDS for MariaDB refuses a connection without TLS (require_secure_transport).
wp config set MYSQL_CLIENT_FLAGS MYSQLI_CLIENT_SSL --raw --type=constant
if ! wp core is-installed 2>/dev/null; then
    log "installing WordPress against $DB_HOST"
    ADMIN_PASSWORD=$(openssl rand -base64 18)
    wp core install --url="$SITE_URL" --title="Novatrix AB" --admin_user=novatrix \
        --admin_password="$ADMIN_PASSWORD" --admin_email=admin@novatrix.example --skip-email
    install -m 0600 /dev/null /root/wordpress-admin
    printf 'user novatrix\npassword %s\n' "$ADMIN_PASSWORD" > /root/wordpress-admin
fi
# The site's address is the load balancer's, the servers' own addresses never.
wp option update home "$SITE_URL"
wp option update siteurl "$SITE_URL"
chown -R apache:apache "$DOCROOT"
flock -u 9
exec 9>&-

systemctl enable --now php-fpm httpd
systemctl restart php-fpm httpd

# --- backup to S3 -----------------------------------------------------------

# A gzipped dump of the database under db/ in the bucket, once a day and once
# now. Every server has the timer; the lock on EFS and the check for a dump
# from today make it one a day. The bucket's lifecycle rule removes each dump
# after 30 days.
cat > /usr/local/bin/wordpress-backup <<'BACKUP'
#!/usr/bin/env bash
set -euo pipefail
source /etc/mov/deploy.env
exec 9>/var/www/html/.mov-backup.lock
flock -w 900 9
TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
export AWS_DEFAULT_REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
NOW=$(date -u +%Y%m%dT%H%M%SZ)
if aws s3 ls "s3://$BACKUP_BUCKET/db/$DB_NAME-${NOW%%T*}" >/dev/null 2>&1; then
    echo "a dump from today is in s3://$BACKUP_BUCKET/db/ already"
    exit 0
fi
SECRET=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET" --query SecretString --output text)
DB_USER=$(python3 -c 'import json, sys; print(json.load(sys.stdin)["username"])' <<<"$SECRET")
export MYSQL_PWD=$(python3 -c 'import json, sys; print(json.load(sys.stdin)["password"])' <<<"$SECRET")
mysqldump --ssl --single-transaction -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" | gzip \
    | aws s3 cp - "s3://$BACKUP_BUCKET/db/$DB_NAME-$NOW.sql.gz"
BACKUP
chmod 0755 /usr/local/bin/wordpress-backup

cat > /etc/systemd/system/wordpress-backup.service <<'UNIT'
[Unit]
Description=WordPress database dump to S3
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wordpress-backup
UNIT

cat > /etc/systemd/system/wordpress-backup.timer <<'UNIT'
[Unit]
Description=WordPress database dump to S3, daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now wordpress-backup.timer
/usr/local/bin/wordpress-backup
log "today's dump in s3://$BACKUP_BUCKET/db/"

# --- record what is actually running ----------------------------------------

install -d -m 0755 "$(dirname "$STAMP")"
cat > "$STAMP" <<JSON
{
  "env": "$MOV_ENV",
  "repo": "$MOV_REPO",
  "ref": "$MOV_REF",
  "commit": "$(git -C "$MOV_APP_DIR" rev-parse HEAD 2>/dev/null || echo unknown)",
  "zone": "$ZONE",
  "deployedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

log "done. $SITE_URL"
