#!/bin/bash
mkdir /run/sshd
mkdir /root/.ssh
cat /tmp/ssh/*pubkey >> /root/.ssh/authorized_keys
cat /tmp/ssh/*.ca | sed -e s/^/'@cert-authority * '/ >> /etc/ssh/ssh_known_hosts
chmod 700 /etc/confluent
chmod go-rwx /etc/confluent/*
for pubkey in /etc/ssh/ssh_host*key.pub; do
    certfile=${pubkey/.pub/-cert.pub}
    privfile=${pubkey%.pub}
    python3 /opt/confluent/bin/apiclient /confluent-api/self/sshcert  $pubkey > $certfile
    if [ -s $certfile ]; then
        if ! grep $certfile /etc/ssh/sshd_config; then
            echo HostCertificate $certfile >> /etc/ssh/sshd_config
        fi
    fi
    if ! grep $privfile /etc/ssh/sshd_config > /dev/null; then
        echo HostKey $privfile >> /etc/ssh/sshd_config
    fi
done
sshconf=/etc/ssh/ssh_config
if [ -d /etc/ssh/ssh_config.d/ ]; then
    sshconf=/etc/ssh/ssh_config.d/01-confluent.conf
fi
echo 'Host *' >> $sshconf
echo '    HostbasedAuthentication yes' >> $sshconf
echo '    EnableSSHKeysign yes' >> $sshconf
echo '    HostbasedKeyTypes *ed25519*' >> $sshconf
confluent_profile=$(grep ^profile: /etc/confluent/confluent.deploycfg | awk '{print $2}')
python3 /opt/confluent/bin/apiclient /confluent-public/os/$confluent_profile/scripts/firstboot.sh > /etc/confluent/firstboot.sh
python3 /opt/confluent/bin/apiclient /confluent-public/os/$confluent_profile/scripts/functions > /etc/confluent/functions
chmod +x /etc/confluent/firstboot.sh
source /etc/confluent/functions
python3 /opt/confluent/bin/apiclient /confluent-api/self/nodelist | sed -e s/'^- //' > /tmp/allnodes
cp /tmp/allnodes /root/.shosts
cp /tmp/allnodes /etc/ssh/shosts.equiv
if grep ^ntpservers: /etc/confluent/confluent.deploycfg > /dev/null; then
    ntps=$(sed -n '/^ntpservers:/,/^[^-]/p' /etc/confluent/confluent.deploycfg|sed 1d|sed '$d' | sed -e 's/^- //' | paste -sd ' ')
    sed -i "s/#NTP=/NTP=$ntps/" /etc/systemd/timesyncd.conf
fi
textcons=$(grep ^textconsole: /etc/confluent/confluent.deploycfg |awk '{print $2}')
updategrub=0
if [ "$textcons" = "true" ] && ! grep console= /proc/cmdline > /dev/null; then
    cons=""
    if [ -f /tmp/autocons.info ]; then
        cons=$(cat /tmp/autocons.info)
    fi
    if [ ! -z "$cons" ]; then
        sed -i 's/GRUB_CMDLINE_LINUX="\([^"]*\)"/GRUB_CMDLINE_LINUX="\1 console='${cons#/dev/}'"/' /etc/default/grub
        updategrub=1
    fi
fi
kargs=$(python3 /opt/confluent/bin/apiclient /confluent-public/os/$confluent_profile/profile.yaml | grep ^installedargs: | sed -e 's/#.*//')
if [ ! -z "$kargs" ]; then
    sed -i 's/GRUB_CMDLINE_LINUX="\([^"]*\)"/GRUB_CMDLINE_LINUX="\1 '"${kargs}"'"/' /etc/default/grub
fi

if [ 1 = $updategrub ]; then
    update-grub
fi

if [ -e /sys/firmware/efi ]; then
    bootnum=$(efibootmgr | grep ubuntu | sed -e 's/ .*//' -e 's/\*//' -e s/Boot//)
    if [ ! -z "$bootnum" ]; then
        currboot=$(efibootmgr | grep ^BootOrder: | awk '{print $2}')
        nextboot=$(echo $currboot| awk -F, '{print $1}')
        [ "$nextboot" = "$bootnum" ] || efibootmgr -o $bootnum,$currboot
        efibootmgr -D
    fi
fi
run_remote_python syncfileclient
run_remote_parts post.d
run_remote_config post


