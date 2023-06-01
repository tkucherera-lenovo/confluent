#!/bin/sh
[ -e /tmp/confluent.initq ] && return 0
if [ -f /tmp/dd_disk ]; then
    for dd in $(cat /tmp/dd_disk); do
        if [ -e $dd ]; then
            driver-updates --disk $dd $dd
        fi
    done
fi
oum=$(umask)
umask 0077
mkdir -p /etc/confluent
cat /tls/*.pem > /etc/confluent/ca.pem
TRIES=5
while [ ! -e /dev/disk ] && [ $TRIES -gt 0 ]; do
    sleep 2
    TRIES=$((TRIES - 1))
done
if [ -e /dev/disk/by-label/CNFLNT_IDNT ]; then
    tmnt=/tmp/idntmnt
    mkdir -p $tmnt
    tcfg=/tmp/idnttmp
    mount /dev/disk/by-label/CNFLNT_IDNT $tmnt
    cd $tmnt
    deploysrvs=$(sed -n '/^deploy_servers:/, /^[^-]/p' cnflnt.yml |grep ^-|sed -e 's/^- //'|grep -v :)
    nodename=$(grep ^nodename: cnflnt.yml|awk '{print $2}')
    sed -n '/^net_cfgs:/, /^[^- ]/{/^[^- ]/!p}' cnflnt.yml |sed -n '/^-/, /^-/{/^-/!p}'| sed -e 's/^[- ]*//'> $tcfg
    autoconfigmethod=$(grep ^ipv4_method: $tcfg)
    autoconfigmethod=${autoconfigmethod#ipv4_method: }
     for i in /sys/class/net/*; do
        ip link set $(basename $i) down
        udevadm info $i | grep ID_NET_DRIVER=cdc_ether > /dev/null &&  continue
        ip link set $(basename $i) up
    done
    for NICGUESS in $(ip link|grep LOWER_UP|grep -v LOOPBACK| awk '{print $2}' | sed -e 's/:$//'); do

TRIES=0
echo -n > /etc/confluent/confluent.info
cd /sys/class/net
while ! awk -F'|' '{print $3}' /etc/confluent/confluent.info |grep 1 >& /dev/null && [ "$TRIES" -lt 60 ]; do
    TRIES=$((TRIES + 1))
    for currif in *; do
        ip link set $currif up
    done
    /opt/confluent/bin/copernicus -t > /etc/confluent/confluent.info
done
cd /
grep ^EXTMGRINFO: /etc/confluent/confluent.info || return 0  # Do absolutely nothing if no data at all yet
echo -n "" > /tmp/confluent.initq
# restart cmdline
echo -n "" > /etc/cmdline.d/01-confluent.conf
nodename=$(grep ^NODENAME /etc/confluent/confluent.info|awk '{print $2}')
#TODO: blkid --label <whatever> to find mounted api

python /opt/confluent/bin/apiclient /confluent-api/self/deploycfg > /etc/confluent/confluent.deploycfg
ifidx=$(cat /tmp/confluent.ifidx)
ifname=$(ip link |grep ^$ifidx:|awk '{print $2}')
ifname=${ifname%:}
echo $ifname > /tmp/net.ifaces

dnsdomain=$(grep ^dnsdomain: /etc/confluent/confluent.deploycfg)
dnsdomain=${dnsdomain#dnsdomain: }
hostname=$nodename
if [ ! -z "$dnsdomain" ] && [ "$dnsdomain" != "null" ]; then
    hostname=$hostname.$dnsdomain
fi
mgr=$(grep ^deploy_server: /etc/confluent/confluent.deploycfg)
mgr=${mgr#deploy_server: }
profilename=$(grep ^profile: /etc/confluent/confluent.deploycfg)
profilename=${profilename#profile: }
proto=$(grep ^protocol: /etc/confluent/confluent.deploycfg)
proto=${proto#protocol: }
textconsole=$(grep ^textconsole: /etc/confluent/confluent.deploycfg)
textconsole=${textconsole#textconsole: }
if [ "$textconsole" = "true" ] && ! grep console= /proc/cmdline > /dev/null; then
	autocons=$(cat /tmp/01-autocons.devnode)
	if [ ! -z "$autocons" ]; then
	    echo Auto-configuring installed system to use text console
	    echo Auto-configuring installed system to use text console > $autocons
	    cp /tmp/01-autocons.conf /etc/cmdline.d/
	else
	    echo "Unable to automatically detect requested text console"
	fi
fi

echo inst.repo=$proto://$mgr/confluent-public/os/$profilename/distribution >> /etc/cmdline.d/01-confluent.conf
echo inst.ks=$proto://$mgr/confluent-public/os/$profilename/kickstart >> /etc/cmdline.d/01-confluent.conf
kickstart=$proto://$mgr/confluent-public/os/$profilename/kickstart
root=anaconda-net:$proto://$mgr/confluent-public/os/$profilename/distribution
export kickstart
export root
autoconfigmethod=$(grep ipv4_method /etc/confluent/confluent.deploycfg)
autoconfigmethod=${autoconfigmethod#ipv4_method: }
if [ "$autoconfigmethod" = "dhcp" ]; then
    echo ip=$ifname:dhcp >>  /etc/cmdline.d/01-confluent.conf
else
    v4addr=$(grep ^ipv4_address: /etc/confluent/confluent.deploycfg)
    v4addr=${v4addr#ipv4_address: }
    v4gw=$(grep ^ipv4_gateway: /etc/confluent/confluent.deploycfg)
    v4gw=${v4gw#ipv4_gateway: }
    if [ "$v4gw" = "null" ]; then
        v4gw=""
    fi
    v4nm=$(grep ipv4_netmask: /etc/confluent/confluent.deploycfg)
    v4nm=${v4nm#ipv4_netmask: }
    echo ip=$v4addr::$v4gw:$v4nm:$hostname:$ifname:none >> /etc/cmdline.d/01-confluent.conf
fi
nameserversec=0
while read -r entry; do
    if [ $nameserversec = 1 ]; then
        if [[ $entry == "-"* ]] && [[ $entry != "- ''" ]]; then
            echo nameserver=${entry#- } >> /etc/cmdline.d/01-confluent.conf
            continue
        fi
    fi
    nameserversec=0
    if [ "${entry%:*}" = "nameservers" ]; then
        nameserversec=1
        continue
    fi
done < /etc/confluent/confluent.deploycfg

