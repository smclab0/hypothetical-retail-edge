#!/bin/bash
# Agama post-install script (runs chrooted in the installed SLES 16 system).
# render-kiosk.sh prepends the extraction of the box payload (enrolment
# service, HQ CA, kiosk session files) to this script.
set -euxo pipefail
S=/usr/share/retail-kiosk

# Store enrolment: same service and program as the SL Micro store image
systemctl enable retail-enrol.service sshd.service

# K3s on SELinux needs k3s-selinux; it is not on the SLES media
rpm --import $S/rancher-public.key
cp $S/k3s-selinux.rpm /tmp/k3s-selinux.rpm
rpm -K /tmp/k3s-selinux.rpm
rpm -Uvh /tmp/k3s-selinux.rpm
rm /tmp/k3s-selinux.rpm

# The store LAN is already isolated by the store router; firewalld would block
# K3s (flannel, kubelet, the till on :80)
systemctl disable firewalld.service || true

# Kiosk session: autologin, no lock or blanking, first-run screens off
install -m 0644 $S/gdm-custom.conf /etc/gdm/custom.conf
install -D -m 0644 $S/dconf-profile-user /etc/dconf/profile/user
install -D -m 0644 $S/dconf-00-kiosk /etc/dconf/db/local.d/00-kiosk
install -D -m 0644 $S/dconf-locks-kiosk /etc/dconf/db/local.d/locks/kiosk
dconf update
install -D -m 0644 $S/firefox-policies.json /etc/firefox/policies/policies.json
install -d -o kiosk -g users /home/kiosk/.config/autostart
install -m 0644 -o kiosk -g users $S/retail-kiosk.desktop /home/kiosk/.config/autostart/retail-kiosk.desktop
echo yes > /home/kiosk/.config/gnome-initial-setup-done
chown kiosk:users /home/kiosk/.config/gnome-initial-setup-done
systemctl set-default graphical.target
