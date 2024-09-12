#!/bin/bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
if [[ $1 == '' ]]; then
	echo "SELINUX=disabled" > /etc/selinux/config 
	SHMALL=$(expr $(getconf _PHYS_PAGES) / 2) 
	SHMAX=$(expr $(getconf _PHYS_PAGES) / 2 \* $(getconf PAGE_SIZE))
	echo "Using shmall=$SHMALL, shmax=$SHMAX"
	echo "
kernel.shmall = $SHMALL
kernel.shmmax = $SHMAX
kernel.shmmni = 4096
vm.overcommit_memory = 2 # See Segment Host Memory
vm.overcommit_ratio = 95 # See Segment Host Memory
net.ipv4.ip_local_port_range = 10000 65535 # See Port Settings
kernel.sem = 250 2048000 200 8192
kernel.sysrq = 1
kernel.core_uses_pid = 1
kernel.msgmnb = 65536
kernel.msgmax = 65536
kernel.msgmni = 2048
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.conf.all.arp_filter = 1
net.ipv4.ipfrag_high_thresh = 41943040
net.ipv4.ipfrag_low_thresh = 31457280
net.ipv4.ipfrag_time = 60
net.core.netdev_max_backlog = 10000
net.core.rmem_max = 2097152
net.core.wmem_max = 2097152
vm.swappiness = 10
vm.zone_reclaim_mode = 0
vm.dirty_expire_centisecs = 500
vm.dirty_writeback_centisecs = 100
vm.dirty_background_ratio = 0 # See System Memory
vm.dirty_ratio = 0
vm.dirty_background_bytes = 1610612736
vm.dirty_bytes = 4294967296
" >> /etc/sysctl.conf
	sysctl -p

	echo "
* soft nofile 524288
* hard nofile 524288
* soft nproc 131072
* hard nproc 131072
" > /etc/security/limits.conf

	echo "
RemoveIPC=no
" > /etc/systemd/logind.conf

	groupadd gpadmin
	useradd gpadmin -r -m -g gpadmin
	sudo -u gpadmin ssh-keygen -t rsa -b 4096
	usermod -aG wheel gpadmin
	echo "%wheel        ALL=(ALL)       NOPASSWD: ALL" >> /etc/sudoers

	grubby --update-kernel=ALL --args="transparent_hugepage=never"

	echo "Please reboot now. Then launch the script with the 'db-install' parameter."

elif [[ $1 == 'db-install' ]]; then
	echo "Database installation"
	yum install -y go
	export GOPROXY=https://goproxy.io,direct
	yum -y install R apr apr-devel apr-util automake autoconf bash bison bison-devel bzip2 bzip2-devel flex flex-devel gcc gcc-c++ git gdb iproute krb5-devel less libevent libevent-devel libxml2 libxml2-devel libyaml libzstd-devel libzstd make openldap openssh openssh-clients openssh-server openssl openssl-devel openssl-libs perl python3-devel readline readline-devel rsync sed sudo tar vim wget which zip zlib python3-pip python3-psycopg2 postgresql15 libpq-devel psutils
	yum install curl libcurl-devel --allowerasing
	yum install https://cdn.amazonlinux.com/2/core/2.0/x86_64/6b0225ccc542f3834c95733dcf321ab9f1e77e6ca6817469771a8af7c49efe6c/../../../../../blobstore/4846e71174e99f1b7f0985aa01631de003633d3a5f1a950812323c175214ae16/xerces-c-3.1.1-10.amzn2.x86_64.rpm
	yum install 	https://cdn.amazonlinux.com/2/core/2.0/x86_64/6b0225ccc542f3834c95733dcf321ab9f1e77e6ca6817469771a8af7c49efe6c/../../../../../blobstore/53208ffe95cd1e38bba94984661e79134b3cc1b039922e828c40df7214ecaee8/xerces-c-devel-3.1.1-10.amzn2.x86_64.rpm

	pip install --break-system-packages PygreSQL psutil
	if [[ $2 != 'no_dl' ]]; then wget https://github.com/cloudberrydb/cloudberrydb/archive/refs/tags/1.5.3.tar.gz; fi
	tar -xzf 1.5.3.tar.gz
	cd cloudberrydb-1.5.3/
	echo -e "/usr/local/lib \n/usr/local/lib64" >> /etc/ld.so.conf
	ldconfig
        ./configure --prefix=/usr/local/cloudberrydb
	make -j8
	make -j8 install
	chown -R gpadmin:gpadmin /usr/local
	chown -R gpadmin:gpadmin /usr/local/cloudberry*
	echo "source /usr/local/cloudberrydb/greenplum_path.sh" >> /home/gpadmin/.bashrc
	echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
	systemctl restart sshd
	passwd gpadmin
	sudo -iu gpadmin ssh-copy-id localhost
	echo "localhost" > /home/gpadmin/hosts
	mkdir -p /data0/primary/
	mkdir -p /data0/mirror/
	mkdir -p /data0/coordinator/
	chown -R gpadmin:gpadmin /data0
	echo "export COORDINATOR_DATA_DIRECTORY=/data0/coordinator/gpseg-1" >> /home/gpadmin/.bashrc
	cp $SCRIPT_DIR/gpinitsystem_config /home/gpadmin/
	chown gpadmin:gpadmin /home/gpadmin/*
	sudo -iu gpadmin gpinitsystem -c  gpinitsystem_config -h hosts
	echo "Database should be up. Run the script with the 'test' paramater to run the tests"

elif [[ $1 == 'test' ]]; then
	echo "Will run tests"
	cd $SCRIPT_DIR
        cp $SCRIPT_DIR/create.sql /home/gpadmin/
        cp $SCRIPT_DIR/queries.sql /home/gpadmin/
        cp $SCRIPT_DIR/run.sh /home/gpadmin/
	chmod +x /home/gpadmin/run.sh
	chown gpadmin:gpadmin /home/gpadmin/*
	if [[ $2 != 'no_dl' ]]; then sudo -iu gpadmin wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'; fi
	if [[ $2 != 'no_dl' ]]; then sudo -iu gpadmin gzip -d hits.tsv.gz; fi
	sudo -iu gpadmin chmod 777 ~ hits.tsv
	sudo -iu gpadmin psql -d postgres -f /home/gpadmin/create.sql
	sudo -iu gpadmin nohup gpfdist &
	if [[ $2 != 'no_dl' ]]; then sudo -iu gpadmin time psql -d postgres -t -c '\timing' -c "insert into hits select * from hits_ext;"; fi
	if [[ $2 != 'no_dl' ]]; then sudo -iu gpadmin psql -d postgres -t -c "ANALYZE hits;"; fi
	du -sh /data0*
	sudo -iu gpadmin /home/gpadmin/run.sh 2>&1 | tee log.txt
	cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

fi
