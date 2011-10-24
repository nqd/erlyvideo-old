#!/bin/bash

Host=$(./contrib/amazon_api get_host $1 $2 $3)
echo $Host
scp pk-*.pem root@$Host:/root/ec2
scp cert-*.pem root@$Host:/root/ec2
scp ec2.pem root@$Host:/root/ec2/etc/ec2/amitools/cert-ec2.pem
scp erlyvideo.tar.bz2 root@$Host:/root
ssh  root@$Host '~/.bash_profile && ./script.sh'
./contrib/amazon_api bterminate $1 $2 $3