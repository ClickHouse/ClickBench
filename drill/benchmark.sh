# Install

sudo apt-get update
sudo apt-get install -y docker.io

# https://drill.apache.org/docs/running-drill-on-docker/

sudo docker run -it --rm --name drill -p 8047:8047 -p 31010:31010 apache/drill
