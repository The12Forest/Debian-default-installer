# su-
# apt install sudo curl -y
# usermod -aG sudo $USER
# exit
# newgrp sudo


sudo apt-get update
sudo apt-get install ca-certificates -y
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y

sudo docker network create -d macvlan --subnet 192.168.188.0/23 --gateway 192.168.188.1 -o parent=enp1s0 VIP

sudo usermod -aG docker $USER

docker run -d -p 9001:9001 --name portainer_agent --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v /var/lib/docker/volumes:/var/lib/docker/volumes -v /:/host portainer/agent:2.21.4


# Cockpit

# su -

sudo curl -sSL https://repo.45drives.com/setup | sudo bash
. /etc/os-release
sudo echo "deb http://deb.debian.org/debian ${VERSION_CODENAME}-backports main" > \
    /etc/apt/sources.list.d/backports.list
sudo apt update
sudo apt install -t ${VERSION_CODENAME}-backports cockpit -y

# exit
# Install cockpit


sudo apt install samba cockpit-storaged cockpit-networkmanager cockpit-file-sharing cockpit-identities  cockpit-benchmark -y

sudo bash -c 'mkdir -p /etc/systemd/system/cockpit.socket.d && echo -e "[Socket]\nListenStream=\nListenStream=443" > /etc/systemd/system/cockpit.socket.d/override.conf && systemctl daemon-reload && systemctl restart cockpit.socket'

sudo systemctl restart cockpit.socket


