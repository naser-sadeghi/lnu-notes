#!/bin/bash
# User data for the DATABASE instance (Ubuntu 24.04).
# Paste into "Advanced details -> User data" when launching, or run by hand.
set -eux

DB_NAME=lnunotes
DB_USER=lnu
DB_PASS='change-me-before-you-launch'      # see the note at the bottom

apt-get update
apt-get install -y mariadb-server

# Listen on all interfaces. This is NOT what makes it reachable — the security
# group decides that. The database is only as private as the rule you write.
sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' /etc/mysql/mariadb.conf.d/50-server.cnf
systemctl restart mariadb

mysql <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

# A question for your report: this script puts a password into EC2 user data,
# which any process on the instance can read from the metadata service.
# Name a better way to do it on AWS, and say what it would cost you in effort.
