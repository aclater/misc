
#!/bin/sh

#
# /etc/NetworkManager/dispatcher.d/00-kinit.sh
#
# By The #TonyJames
#

VPN_UUID="71f1c668-a681-47b7-b683-f0dc0a319cb9"
USER="tony"

if [ ${CONNECTION_UUID} == ${VPN_UUID} ] && [ ${NM_DISPATCHER_ACTION} == "vpn-up" ]; then
  su - ${USER} -c "/usr/bin/krb5-auth-dialog --display :0" &
fi
