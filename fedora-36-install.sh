#!/bin/bash

RED='\033[1;31m'
NC='\033[0m' # No Color

dev_env_flag=
while getopts 'd' OPTION
do
    case $OPTION in
    d)    dev_env_flag=1
          ;;
    ?)    echo "Usage: fedora-36-install.sh [ -d ]"
          return 2
          ;;
    esac
done

function install_os_tools() {
    sudo dnf -y upgrade
    sudo dnf -y install alsa-lib pipewire-alsa
    sudo dnf -y install lsscsi net-tools
    sudo dnf -y  install avahi && sudo systemctl restart avahi-daemon
    sudo dnf -y install git

}

function add_arm_user() {
    echo -e "${RED}Adding arm user${NC}"
    # create arm group if it doesn't already exist
    if ! [ $(getent group arm) ]; then
        sudo groupadd arm
    else
        echo -e "${RED}arm group already exists, skipping...${NC}"
    fi

    # create arm user if it doesn't already exist
    if ! id arm >/dev/null 2>&1; then
        sudo useradd -m arm -g arm
        sudo passwd arm
    else
        echo -e "${RED}arm user already exists, skipping creation...${NC}"
    fi
    sudo usermod -aG cdrom,video arm
}

function install_dev_requirements() {
    echo -e "${RED}Installing ARM requirments${NC}"
    sudo dnf install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
    sudo dnf -y groupinstall "Development Tools"
    sudo dnf -y update
    sudo dnf -y install makemkv-bin makemkv-oss -y
    sudo dnf -y install HandBrake libavcidec-free libavcodec-free-devel
    sudo dnf -y install abcde flac flac-libs flac-devel imagemagick ImageMagick-libs ImageMagick-devel glyr glyr-libs \
    cdparanoia cdparanoia-devel cdparanoia-libs cdparanoia-static
    sudo dnf -y install at
    sudo dnf -y install python3 python3-pip -y
    sudo dnf -y install openssl openssl-devel libcurl libcurl-devel curl
    sudo dnf -y install libdvdcss libdvdread libdvdnav libdvdcss-devel libdvdread-devel libdvdnav-devel
    sudo dnf -y install lsdvd -y
    sudo dnf -y install java-openjdk-headless

    sudo dnf -y install zlib zlib-devel expat expat-devel ffmpeg ffmpeg-devel qt5-qtbase-devel ffmpeg-libs
    
    # Installing snap in order to get makemkv
    sudo dnf -y install snapd
    sudo ln -s /var/lib/snapd/snap /snap
    sudo snap install makemkv
    sudo ln -s /snap/bin/makemkv /usr/bin/makemkv
    sudo ln -s /snap/bin/makemkvcon /usr/bin/makemkvcon
    sudo ln -s /snap/bin/makemkv.makemkvcon /usr/bin/makemkv.makemkvcon
}


function remove_existing_arm() {
    # check if the armui service exists in any state
    if sudo systemctl list-unit-files --type service | grep -F armui.service; then
        echo -e "${RED}Previous installation of ARM service found. Removing...${NC}"
        service=armui.service
        sudo systemctl stop $service && sudo systemctl disable $service
        sudo find /etc/systemd/system/$service -delete
        sudo systemctl daemon-reload && sudo systemctl reset-failed
    fi
}

function clone_arm() {
    if [ -d arm ]; then
        echo -e "${RED}Existing ARM installation found, removing...${NC}"
        sudo rm -rf arm
    fi
    sudo mkdir -p arm
    sudo chown arm:arm arm
    sudo chmod 775 arm
    git clone https://github.com/automatic-ripping-machine/automatic-ripping-machine.git arm
    sudo chown -R arm:arm arm
}

function create_abcde_symlink() {
    if ! [[ -z $(find /home/arm/ -type l -ls | grep ".abcde.conf") ]]; then
        rm /home/arm/.abcde.conf
    fi
    sudo ln -sf /opt/arm/setup/.abcde.conf /home/arm/
}

function create_arm_config_symlink() {
    if ! [[ -z $(find /etc/arm/ -type l -ls | grep "arm.yaml") ]]; then
        rm /etc/arm/arm.yaml
    fi
    sudo ln -sf /opt/arm/arm.yaml /etc/arm/
}

function install_arm_live_env() {
    echo -e "${RED}Installing ARM:Automatic Ripping Machine${NC}"
    cd /opt
    clone_arm
    cd arm
    sudo pip3 install -r requirements.txt
    sudo cp /opt/arm/setup/51-automedia.rules /etc/udev/rules.d/
    create_abcde_symlink
    sudo cp docs/arm.yaml.sample arm.yaml
    sudo chown arm:arm arm.yaml
    sudo mkdir -p /etc/arm/
    create_arm_config_symlink
    sudo chmod +x /opt/arm/scripts/arm_wrapper.sh
    sudo chmod +x /opt/arm/scripts/update_key.sh
}

function install_arm_dev_env() {
    # install arm without automation and with PyCharm
    echo -e "${RED}Installing ARM for Development${NC}"
    cd /home/arm
    sudo snap install pycharm-community --classic
    cd /opt
    clone_arm
    cd arm
    sudo pip3 install -r requirements.txt
    create_abcde_symlink
    sudo cp docs/arm.yaml.sample arm.yaml
    sudo chown arm:arm arm.yaml
    sudo mkdir -p /etc/arm/
    create_arm_config_symlink

    # allow developer to write to the installation
    sudo chmod -R 777 /opt/arm
}

function setup_autoplay() {
    ######## Adding new line to fstab, needed for the autoplay to work.
    ######## also creating mount points (why loop twice)
    echo -e "${RED}Adding fstab entry and creating mount points${NC}"
    for dev in /dev/sr?; do
        if grep -q "${dev}    /mnt${dev}    udf,iso9660    users,noauto,exec,utf8    0    0" /etc/fstab; then
            echo -e "${RED}fstab entry for ${dev} already exists. Skipping...${NC}"
        else
            echo -e "\n${dev}    /mnt${dev}    udf,iso9660    users,noauto,exec,utf8    0    0 \n" | sudo tee -a /etc/fstab
        fi
        sudo mkdir -p /mnt$dev
    done
}

function setup_syslog_rule() {
    ##### Add syslog rule to route all ARM system logs to /var/log/arm.log
    if [ -f /etc/rsyslog.d/30-arm.conf ]; then
        echo -e "${RED}ARM syslog rule found. Overwriting...${NC}"
        sudo rm /etc/rsyslog.d/30-arm.conf
    fi
    sudo cp ./scripts/30-arm.conf /etc/rsyslog.d/30-arm.conf
}

function install_armui_service() {
    ##### Run the ARM UI as a service
    echo -e "${RED}Installing ARM service${NC}"
    sudo mkdir -p /etc/systemd/system
    sudo cp ./scripts/armui.service /etc/systemd/system/armui.service

    sudo systemctl daemon-reload
    sudo chmod u+x /etc/systemd/system/armui.service
    sudo chmod 600 /etc/systemd/system/armui.service

    #reload the daemon and then start ui
    sudo systemctl start armui.service
    sudo systemctl enable armui.service
    sudo sysctl -p
}

function launch_setup() {
    echo -e "${RED}Launching ArmUI first-time setup${NC}"
    site_addr=`sudo netstat -tlpn | awk '{ print $4 }' | grep .*:8080`
    if [ -z $site_addr ]; then
        echo -e "${RED}ERROR: ArmUI site is not running. Run \"sudo systemctl status armui\" to find out why${NC}"
    else
        echo -e "${RED}ArmUI site is running on http://$site_addr. Launching setup...${NC}"
        sudo -u arm nohup xdg-open http://$site_addr/setup > /dev/null 2>&1 &
    fi
}

# start here
install_os_tools
add_arm_user
install_dev_requirements
remove_existing_arm

if [ "$dev_env_flag" ]; then
    install_arm_dev_env
else
    install_arm_live_env
fi

setup_autoplay
setup_syslog_rule
install_armui_service
launch_setup

#advise to reboot
echo
echo -e "${RED}We recommend rebooting your system at this time.${NC}"
echo
