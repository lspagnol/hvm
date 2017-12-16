#!/bin/bash

mkdir -p /usr/local/hvm/
chown root:root /usr/local/hvm/
chmod 750 /usr/local/hvm/

mkdir -p /var/lib/hvm
chown root:root /var/lib/hvm
chmod 750 /var/lib/hvm

mkdir -p /usr/local/hvm/etc/
cp -r etc/* /usr/local/hvm/etc/
chown -R root:root /usr/local/hvm/etc/
find /usr/local/hvm/etc/ -type d -exec chmod -R 750 {} \;
find /usr/local/hvm/etc/ -type f -exec chmod -R 640 {} \;
cp /usr/local/hvm/etc/common.conf.dist /usr/local/hvm/etc/common.conf
[ -f /usr/local/hvm/etc/local.conf ] || cp /usr/local/hvm/etc/local.conf.dist /usr/local/hvm/etc/local.conf
[ -f /usr/local/hvm/etc/hv_pre-start.sh ] || cp /usr/local/hvm/etc/hv_pre-start.sh.dist /usr/local/hvm/etc/hv_pre-start.sh
[ -f /usr/local/hvm/etc/hv_post-stop.sh ] || /usr/local/hvm/etc/hv_post-stop.sh.dist /usr/local/hvm/etc/hv_post-stop.sh

mkdir -p /usr/local/hvm/sbin/
cp sbin/* /usr/local/hvm/sbin/
chown -R root:root /usr/local/hvm/sbin/
find /usr/local/hvm/sbin/ -type d -exec chmod -R 750 {} \;
find /usr/local/hvm/sbin/ -type f -exec chmod -R 640 {} \;
chmod 750 /usr/local/hvm/sbin/hvm
chmod 750 /usr/local/hvm/sbin/hvm-cron
chmod 750 /usr/local/hvm/sbin/hvmd
chmod 750 /usr/local/hvm/sbin/hvm-interface-config
ln -fs /usr/local/hvm/sbin/hvm /usr/local/sbin
ln -fs /usr/local/hvm/sbin/hvm-interface-config /usr/local/sbin/

cp init/hvmd /etc/init.d
chmod 750 /etc/init.d/hvmd
update-rc.d -f hvmd defaults

mkdir -p /usr/local/hvm/lib/
cp lib/* /usr/local/hvm/lib/
find /usr/local/hvm/lib/ -type d -exec chmod -R 750 {} \;
find /usr/local/hvm/lib/ -type f -exec chmod -R 640 {} \;

mkdir -p /usr/local/hvm/doc/
cp -r doc/* /usr/local/hvm/doc/
find /usr/local/hvm/doc/ -type d -exec chmod -R 750 {} \;
find /usr/local/hvm/doc/ -type f -exec chmod -R 640 {} \;
test -h /usr/local/hvm/doc/hvm_help.txt || ln -s /usr/local/hvm/doc/hvm_help-fr.txt /usr/local/hvm/doc/hvm_help.txt

