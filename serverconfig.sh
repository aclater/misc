#!/bin/bash

dnf -y update

# Enable appstream baseos epel epel-next extras-common and crb if available
dnf config-manager --set-enabled appstream baseos epel epel-next extras-common crb

# Add repos for EPEL, RPMFusion, RPMFusion non-free, CERT Forensics

dnf -y install --nogpgcheck https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm
dnf -y install --nogpgcheck https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-$(rpm -E %rhel).noarch.rpm https://mirrors.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-$(rpm -E %rhel).noarch.rpm https://forensics.cert.org/cert-forensics-tools-release-el9.rpm

dnf -y install unrar python-devel pip tuned
dnf -y groupinstall "Development Tools"

dnf -y update

# Enable tuned and enable powersave profile
systemctl enable --now tuned
tuned-adm profile powersave

# Add a group for media

groupadd media

# Add users for lidarr radarr sonarr prowlarr
# put them into the media group
# set ownership on /opt & /var/lib resources
# ${i^} prints $i with the first letter capitalized

for i in lidarr radarr sonarr prowlarr
do
	useradd $i -G media
	chown -R $i:$i /var/lib/${i^}
done

#now add user and set permissions for sabnzbd
useradd sabnzbd -G media
chown -R sabnzbd:sabnzbd /opt/sabnzbd


# set SELinux labels on /opt directories
restorecon -rv /opt/*arr /opt/sabnzbd 

# Best to install sabnzbd python requirements as sabnzbd user and not pollute system python
sudo -u sabnzbd pip install wheel
sudo -u sabnzbd pip install sabyenc

# Need to run pip install of SAB requirements twice because some later
# requirements fail the first go-round

sudo -u sabnzbd pip install -r /opt/sabnzbd/requirements.txt
sudo -u sabnzbd pip install -r /opt/sabnzbd/requirements.txt

# Firewall Setup

# Reload services from /etc/firewalld/services/
firewall-cmd --reload

# Enable our services
for i in lidarr prowlarr radarr roon-server sabnzbd sonarr
do
	firewall-cmd --permanent --enable-service=$i
done

# Start services
systemctl enable --now lidarr radarr sonarr prowlarr sabnzbd

echo RoonServer not started - make sure it is installed and roon user is added to media group
