#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
CWD="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

SSH_PORT=7432

if [ ! -f /etc/redhat-release ]; then
	echo "CentOS no detectado, abortando."
	exit 0
fi

echo "Actualizando SO..."
yum update -y
yum groupinstall "Base" --skip-broken -y
yum install screen -y
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/sysconfig/selinux
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
/usr/sbin/setenforce 0
iptables-save > /root/firewall.rules

echo "Configurando Red..."
find /etc/sysconfig/network-scripts/ -name "ifcfg-*" -not -name "ifcfg-lo" | while read ETHCFG
do
	sed -i '/^PEERDNS=.*/d' $ETHCFG
	sed -i '/^DNS1=.*/d' $ETHCFG
	sed -i '/^DNS2=.*/d' $ETHCFG
	
	echo "PEERDNS=no" >> $ETHCFG
	echo "DNS1=9.9.9.9" >> $ETHCFG
	echo "DNS2=8.8.8.8" >> $ETHCFG

done

echo "Reescribiendo /etc/resolv.conf..."

echo "nameserver 9.9.9.9" > /etc/resolv.conf # QuadNine
echo "nameserver 149.112.112.112" >> /etc/resolv.conf # Google


echo "Configurando SSH..."
sed -i 's/^X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config
sed -i 's/#UseDNS.*/UseDNS no/' /etc/ssh/sshd_config

echo "Cambiando puerto SSH..."
if [ -d /etc/csf ]; then
	echo "Abriendo CSF..."
        CURR_CSF_IN=$(grep "^TCP_IN" /etc/csf/csf.conf | cut -d'=' -f2 | sed 's/\ //g' | sed 's/\"//g' | sed "s/,$SSH_PORT,/,/g" | sed "s/,$SSH_PORT//g" | sed "s/$SSH_PORT,//g" | sed "s/,,//g")
        sed -i "s/^TCP_IN.*/TCP_IN = \"$CURR_CSF_IN,$SSH_PORT\"/" /etc/csf/csf.conf
        csf -r
fi

echo "Cambiando puerto SSH default 22 a $SSH_PORT..."
sed -i "s/^\(#\|\)Port.*/Port $SSH_PORT/" /etc/ssh/sshd_config

service sshd restart

# FIREWALL

# SI TIENE SOLO IPTABLES
if [ -f /etc/sysconfig/iptables ]; then
	sed -i 's/dport 22 /dport $SSH_PORT /' /etc/sysconfig/iptables
	service iptables restart 2>/dev/null
fi

# SI TIENE FIREWALLD
if systemctl is-enabled firewalld | grep "^enabled$" > /dev/null; then
	if systemctl is-active firewalld | grep "^inactive$" > /dev/null; then
		service firewalld restart
	fi
	firewall-cmd --permanent --add-port=$SSH_PORT/tcp > /dev/null
	firewall-offline-cmd --add-port=$SSH_PORT/tcp > /dev/null
	firewall-cmd --reload 
fi

echo "Configurando FSCK..."
grubby --update-kernel=ALL --args=fsck.repair=yes
grep "fsck.repair" /etc/default/grub > /dev/null || sed 's/^GRUB_CMDLINE_LINUX="/&fsck.repair=yes /' /etc/default/grub

echo "Configurando Yum-Cron..."
yum -y install yum-cron
sed -i 's/^apply_updates.*/apply_updates = yes/' /etc/yum/yum-cron.conf
systemctl start yum-cron.service

echo "Configurando SSD (de poseer)..."
for DEVFULL in /dev/sg? /dev/sd?; do
	DEV=$(echo "$DEVFULL" | cut -d'/' -f3)
        if [ -f "/sys/block/$DEV/queue/rotational" ]; then
        	TYPE=$(grep "0" /sys/block/$DEV/queue/rotational > /dev/null && echo "SSD" || echo "HDD")
		if [ "$TYPE" = "SSD" ]; then
			systemctl enable fstrim.timer

		fi
        fi
done

echo "Sincronizando fecha con ntp.shoa.cl..."
ntpdate ntp.shoa.cl
if [ -f /usr/share/zoneinfo/America/Santiago ]; then
        echo "Seteando timezone a America/Santiago..."
        mv /etc/localtime /etc/localtime.old
        ln -s /usr/share/zoneinfo/America/Santiago /etc/localtime
fi

echo "Seteando fecha del BIOS..."
hwclock -r

echo "Instalando GIT..."
yum install git -y

echo "Instalando CRON clean de Journal..."
echo "30 22 * * * root /usr/bin/journalctl --vacuum-time=1d; /usr/sbin/service systemd-journald restart" > /etc/cron.d/clean_journal
service crond restart

echo "Finalizado!"
