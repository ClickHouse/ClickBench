Greenplum requires ubuntu 18.04.
Also scripts should be run from `gpadmin` user.

Something around these should be enough:

``` bash
sudo useradd gpadmin -m
sudo passwd gpadmin
sudo usermod -aG sudo gpadmin
sudo -iu gpadmin bash
```

It is important that the `HOME` directory has the right permissions - `755`.
