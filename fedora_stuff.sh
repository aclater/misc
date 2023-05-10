#
# Add Repos
#



# RPMFusion

sudo dnf -y  install https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# RHEL9 EPEL
#sudo rpm -Uvh https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

#sudo dnf -y install https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-9.noarch.rpm
#sudo dnf -y install https://mirrors.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-9.noarch.rpm
# Microsoft Repo
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
sudo sh -c 'echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/vscode.repo'
sudo rpm -Uvh https://packages.microsoft.com/config/sles/15/packages-microsoft-prod.rpm

# Install Red Hat internal Repo, Cert & VPN

sudo rpm --import https://hdn.corp.redhat.com/rhel8-csb/RPM-GPG-KEY-helpdesk
sudo dnf config-manager --add-repo https://hdn.corp.redhat.com/rhel8-csb/rhel8-csb.repo

#
# Add groups
#
sudo dnf -y  groupupdate core
sudo dnf -y  groupupdate multimedia --setop="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin
sudo dnf -y  groupupdate sound-and-video

#
# Install packages
#

# Misc RPMFusion packages and gnome extensions

sudo dnf -y  install rpmfusion-free-release-tainted libdvdcss rpmfusion-nonfree-release-tainted \*-firmware gnome-shell-extension-common gnome-shell-extension-user-theme gnome-shell-extension-freon gnome-shell-extension-no-overview gnome-shell-extension-sound-output-device-chooser gnome-shell-extension-openweather gnome-shell-extension-dash-to-dock

# Red Hat OpenVPN profiles for NetworkManager and Red Hat internal certificate
sudo dnf install redhat-internal-NetworkManager-openvpn-profiles redhat-internal-cert-install

# Microsoft Edge & Visual Studio Code
sudo dnf -y install microsoft-edge-beta code

# Install Google Chrome
sudo dnf -y install https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm

#
# Install NVIDIA Drivers from rpmFusion
#
sudo dnf update -y # and reboot if you are not on the latest kernel
sudo dnf install akmod-nvidia # rhel/centos users can use kmod-nvidia instead
sudo dnf install xorg-x11-drv-nvidia-cuda #optional for cuda/nvdec/nvenc support

#
#Fix font display issue
#

sudo dnf -y install freetype-freeworld
echo "Xft.lcdfilter: lcddefault" > ~/.Resources
gsettings "set" "org.gnome.settings-daemon.plugins.xsettings" "hinting" "slight"
gsettings "set" "org.gnome.settings-daemon.plugins.xsettings" "antialiasing" "rgba"
xrdb -query
