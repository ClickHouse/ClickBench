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

Create a bucket in s3 for Hydrolix. I've named it `hydrolix-test`.
Then run:

```
sudo enable-hdxreader eu-west-3 hydrolix-test /
wget -O hdxctl https://docs.hydrolix.io/docs/download/hdxctl && chmod +x hdxctl
sudo mv hdxctl /usr/local/bin/
```

The hdxctl tool does not work out of the box with a cryptic error:
```
$ hdxctl version
Traceback (most recent call last):
  File "/usr/lib/python3.10/runpy.py", line 196, in _run_module_as_main
    return _run_code(code, main_globals, None,
  File "/usr/lib/python3.10/runpy.py", line 86, in _run_code
    exec(code, run_globals)
  File "/usr/local/bin/hdxctl/__main__.py", line 3, in <module>
  File "/usr/local/bin/hdxctl/_bootstrap/__init__.py", line 195, in bootstrap
  File "/usr/local/bin/hdxctl/_bootstrap/__init__.py", line 125, in extract_site_packages
  File "/usr/local/bin/hdxctl/_bootstrap/filelock.py", line 71, in __enter__
  File "/usr/local/bin/hdxctl/_bootstrap/filelock.py", line 39, in acquire_nix
PermissionError: [Errno 13] Permission denied: '/home/ubuntu/.shiv/.hdxctl_ecb57208c863c87704210138416f924b2cd43c3c8b0bc101cad6a2493a82db9a_lock'
```
 
The following step needed:

```
sudo chmod 777 /home/ubuntu/.shiv/
```

Now it works:
```
hdxctl version
v3.11.11
```

> Congratulations that's the boring bit done! The next step is to deploy the platform! Huzzah!

I don't know what is "huzzah" and prefer not to know.

> hdxctl --region <region> create-cluster <client_Id> --wait

But how to know my client id?
