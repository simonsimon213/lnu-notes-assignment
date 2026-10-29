#!/bin/bash
# User data for the DATABASE instance (Ubuntu 24.04).
# Paste into "Advanced details -> User data" when launching, or run by hand.
set -eux

DB_NAME=lnunotes
DB_USER=lnu
DB_PASS='CHANGE-ME'                        # render this file, do not edit it in place

apt-get update
apt-get install -y mariadb-server

# Listen on all interfaces. This is NOT what makes it reachable — the security
# group decides that. The database is only as private as the rule you write.
#
# Write a drop-in rather than editing 50-server.cnf. On Ubuntu 24.04 the
# bind-address line in that file is commented out, so a sed for '^bind-address'
# matches nothing, exits 0, and leaves MariaDB on 127.0.0.1 — which looks like
# "Connection refused" from the web instance and nothing like a failed command.
cat > /etc/mysql/mariadb.conf.d/99-bind.cnf <<'CNF'
[mysqld]
bind-address = 0.0.0.0
CNF
systemctl restart mariadb

# Prove it before going further; the log is the only evidence you will get.
ss -lntp | grep ':3306' || echo "WARNING: nothing listening on 3306"


mysql <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

# A question for your report: this script puts a password into EC2 user data,
# which any process on the instance can read from the metadata service.
# Name a better way to do it on AWS, and say what it would cost you in effort.
