#!/bin/bash

sudo apt-get update -y
sudo apt-get install -y docker.io
sudo docker run --network host -p 8080:8080 --name trino trinodb/trino

sudo docker exec -i trino trino

CREATE SCHEMA memory.test;
USE memory.test;
