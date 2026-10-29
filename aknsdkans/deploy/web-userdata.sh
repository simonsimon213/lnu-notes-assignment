#!/bin/bash
# User data for the WEB instance (Ubuntu 24.04).
# Edit REPO, then paste into "Advanced details -> User data" at launch.
set -eux

REPO=https://github.com/CHANGE-ME/lnu-notes.git
APP=/opt/lnu-notes

apt-get update
apt-get install -y python3-venv python3-pip git

git clone "$REPO" "$APP"
python3 -m venv "$APP/.venv"
"$APP/.venv/bin/pip" install --quiet -r "$APP/requirements.txt"

# The environment file. Fill in the four values, then restart the service.
cat > /etc/lnu-notes.env <<'ENV'
DB_HOST=CHANGE-ME-private-ip-of-db-instance
DB_USER=lnu
DB_PASS=change-me-before-you-launch
DB_NAME=lnunotes
S3_BUCKET=CHANGE-ME-your-globally-unique-bucket
AWS_REGION=eu-north-1
ENV
chmod 600 /etc/lnu-notes.env

install -m 644 "$APP/deploy/lnu-notes.service" /etc/systemd/system/lnu-notes.service
systemctl daemon-reload
systemctl enable --now lnu-notes

# Nothing here configures AWS credentials, because nothing should:
# attach an IAM role to this instance instead.
