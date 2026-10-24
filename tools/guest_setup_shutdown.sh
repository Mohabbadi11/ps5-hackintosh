#!/bin/bash
#
# PS5 Hackintosh — macOS-side setup for clean shutdowns (run INSIDE macOS)
#
# Authorizes the PS5 host's key for SSH and allows `shutdown` without a
# password, so tools/stop_qemu.sh can power macOS off cleanly. The host serves
# this script on 127.0.0.1:8000, which the guest sees as 10.0.2.2:
#
#   curl -s http://10.0.2.2:8000/guest_setup_shutdown.sh | bash
#
# Prerequisite: System Settings -> Sharing -> Remote Login = ON.

set -e
HOST="${HOST:-10.0.2.2:8000}"

echo "Fetching the PS5 shutdown key..."
PUBKEY="$(curl -fsS "http://$HOST/hackintosh_guest.pub")"

mkdir -p ~/.ssh
chmod 700 ~/.ssh
grep -qxF "$PUBKEY" ~/.ssh/authorized_keys 2>/dev/null || echo "$PUBKEY" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

echo "Allowing passwordless shutdown for $USER (asks for your password once)..."
echo "$USER ALL=(root) NOPASSWD: /sbin/shutdown" | sudo tee /etc/sudoers.d/hackintosh-shutdown >/dev/null
sudo chmod 440 /etc/sudoers.d/hackintosh-shutdown
sudo visudo -cf /etc/sudoers.d/hackintosh-shutdown

curl -fsS "http://$HOST/done?user=$USER" >/dev/null || true
echo "Done. You can close this window."
