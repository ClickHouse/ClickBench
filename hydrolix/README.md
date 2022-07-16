Incomplete.

Hydrolix is a ClickHouse derivative.

Find Hydrolix in AWS Marketplace. Subscribe.

It is not available in eu-central-1 region. Let's select "Paris" (eu-west-3) region.

Choose c5n.4xlarge

Look at the created instance in the EC2 instance list.
Edit the security group. Edit inbound rules. Enable inbound traffic on port 22 (ssh).

```
ssh -i ~/.ssh/aws_eu_west_3.pem ubuntu@35.181.8.173
```

Create a bucket in s3 for Hydrolix, then run:

```
sudo enable-hdxreader eu-west-3 hydrolix-test /
wget -O hdxctl https://docs.hydrolix.io/docs/download/hdxctl && chmod +x hdxctl
```
