#!/bin/bash

cat /etc/os-release | grep 'ID=ubuntu' > /dev/null
RC=$?

if [ $RC -eq 1 ]; then
 echo 'Not running an Ubuntu OS, make sure docker, java, and ripgrep are installed'
 exit
fi

# Install docker
sudo apt-get update
sudo apt-get install ca-certificates curl gnupg -y
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y

# Make sure docker is running
sudo systemctl start docker

# Install java for kisql and rg for run.sh
sudo apt-get install openjdk-21-jre-headless ripgrep -y
