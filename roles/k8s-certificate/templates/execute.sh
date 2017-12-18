#!/usr/bin/env bash

cd /root/ssl/
sh get-certificate.sh

mkdir -p /etc/kubernetes/ssl
cp *.pem /etc/kubernetes/ssl