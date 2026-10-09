#!/bin/sh
# Buildroot post-build hook for fk-rv32 ($1 = target directory).
# The kernel is built without networking, so drop the services that need it
# (they would only print errors and slow the boot down in simulation).
set -e
TARGET_DIR=$1
rm -f "$TARGET_DIR"/etc/init.d/S01syslogd \
      "$TARGET_DIR"/etc/init.d/S02klogd \
      "$TARGET_DIR"/etc/init.d/S40network
