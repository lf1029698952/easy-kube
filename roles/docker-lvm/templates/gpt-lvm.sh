#!/bin/bash

set -o errexit
set -o pipefail

#大容量GPT硬盘中，裸硬盘不可以直接用于创建PV，先将该硬盘创建分区，从分区中创建PV
#fdisk /dev/sdb/ 一路回车,w写入即可

function prepare_system_disk()
{
	# get the size from env(come from node install)
	if [[ -z ${DOCKER_THINPOOL} || -z ${KUBERNETES_LV} ]]; then
		DOCKER_THINPOOL="vgpaas/50%VG"
		KUBERNETES_LV="vgpaas/50%VG"
	fi
	docker_thinpool_size=${DOCKER_THINPOOL##*/}
	k8s_lv_size=${KUBERNETES_LV##*/}
	echo "data disk will allocate $docker_thinpool_size for docker and $k8s_lv_size for kubelet."

	# first step
	# find available block devices
	block_devices=()

	all_devices=$(lsblk -o KNAME,TYPE | grep part | grep -v nvme | awk '{print $1}' | awk '{ print "/dev/"$1}')

set +e
	for device in ${all_devices[@]}; do
		echo "Checking device: ${device}"

		if [ ! -b $device ]; then
			# Check for the xvd-style name
			xvd_style=$(echo $device | sed "s/sd/xvd/")
			if [ -b $xvd_style ]; then
				device="$xvd_style"
			fi
		fi

		# distinguish device is raw disk or partition
		isRawDisk=$(sudo lsblk -n $device 2>/dev/null | grep disk | wc -l)
		if [[ ${isRawDisk} > 0 ]]; then
			# is it partitioned ?
			match=$(sudo lsblk -n $device 2>/dev/null | grep -v disk | wc -l)
			if [[ ${match} > 0 ]]; then
				# already partited
				echo "Raw disk ${device} has been partition, will skip this device"
				continue
			fi
		else
#			isPart=$(sudo lsblk -n $device 2>/dev/null | grep part | wc -l)
#			if [[ ${isPart} -ne 1 ]]; then
#				# not parted
#				echo "Disk ${device} has not been partition, will skip this device"
#				continue
#			fi
			# is used ?
			match=$(sudo lsblk -n $device 2>/dev/null | grep -v part | wc -l)
			if [[ ${match} > 1 ]]; then
				# already used
				echo "Disk ${device} has been used, will skip this device"
				continue
			fi
			isMount=$(sudo lsblk -n -o MOUNTPOINT $device 2>/dev/null)
			if [[ -n ${isMount} ]]; then
				# already used
				echo "Disk ${device} has been used, will skip this device"
				continue
			fi
#			isLvm=$(sudo sfdisk -lqL 2>>/dev/null | grep $device | grep "8e.*Linux LVM")
#			if [[ ! -n ${isLvm} ]]; then
#				# part system type is not Linux LVM
#				echo "Disk ${device} system type is not Linux LVM, will skip this device"
#				continue
#			fi
		fi

		echo "  Detected paas disk: ${device}"
		block_devices+=(${device})
	done
set -e


	# second step
	# format the disks

	if [[ ${#block_devices[@]} == 0 ]]; then
		echo "Failed because of no block devices for docker"
		exit  1
	fi

set +e
	sudo systemctl stop docker
	# for cannot use * in sudo if user dont have access to this dir
	sudo bash -c '/bin/rm -rf /var/lib/docker/*'
set -e

	docker_device=${block_devices[0]}

	echo "Use ${docker_device[@]} to config direct-lvm mode for docker"


	# Remove any existing mounts
	echo "Unmounting ${docker_device[@]}"
set +e
	sudo /bin/umount ${docker_device[@]}
set -e
	for device in ${docker_device[@]}; do
		sudo sed -i -e "\|^${device}|d" /etc/fstab
	done

	# clean possibly exists physical volume and volume group
set +e
	umount /mnt/paas/kubernetes -f
	sudo pvremove ${docker_device[@]} -f
	sudo rm -rf /etc/docker/daemon.json
	sudo rm -rf /etc/lvm/profile/vgpaas-thinpool.profile
	sudo sed -i '/^\/dev\/.*\/mnt\/paas\/kubernetes/d' /etc/fstab
set -e

	# 1. create physical volume
	echo "Step one. Create physical volume..."
	sudo pvcreate ${docker_device[@]} -f

	# 2. create volume group
	echo "Step two. Create volume group..."
	sudo vgcreate vgpaas ${docker_device[@]}

	# 3. create logical volumes
	echo "Step three. Create logical volumes..."
	isExtents=$(echo ${docker_thinpool_size} | grep "%" || :)
	if [[ -n ${isExtents} ]]; then
			thinp_size=${docker_thinpool_size%%%*}
			# remain some space 5%
			thinp_size=$(awk 'BEGIN{print 0.95*'${thinp_size}'}')
			thinp_size=$((${thinp_size//.*/}))

			dockerdatasize=$(awk 'BEGIN{print 0.95*'${thinp_size}'}')
			dockerdatasize=$((${dockerdatasize//.*/}))
			dockermetasize=`expr $thinp_size - $dockerdatasize`
			echo "create logical volume thinpool($dockerdatasize) and thinpoolmeta($dockermetasize)."
			sudo lvcreate -y --wipesignatures y -n thinpool vgpaas -l ${dockerdatasize}%${docker_thinpool_size##*%}
			sudo lvcreate -y --wipesignatures y -n thinpoolmeta vgpaas -l ${dockermetasize}%${docker_thinpool_size##*%}
		else
			strlen=${#docker_thinpool_size}
			thinp_size=${docker_thinpool_size:0:${strlen}-1}
			# remain some space 5%
			thinp_size=$(awk 'BEGIN{print 0.95*'${thinp_size}'}')
			thinp_size=$((${thinp_size//.*/}))

			dockerdatasize=$(awk 'BEGIN{print 0.95*'${thinp_size}'}')
			dockerdatasize=$((${dockerdatasize//.*/}))
			dockermetasize=`expr $thinp_size - $dockerdatasize`
			echo "create logical volume thinpool($dockerdatasize) and thinpoolmeta($dockermetasize)."
			sudo lvcreate -y --wipesignatures y -n thinpool vgpaas -L ${dockerdatasize}${docker_thinpool_size:${strlen}-1}
			sudo lvcreate -y --wipesignatures y -n thinpoolmeta vgpaas -L ${dockermetasize}${docker_thinpool_size:${strlen}-1}
		fi

	# create kubernetes lv for kubelet use
	k8s_size=${k8s_lv_size%%%*}
	echo "create logical volume kubernetes($k8s_size)."
	if [[ -n ${k8s_size} ]]; then
		sudo lvcreate -y --wipesignatures y -n kubernetes vgpaas -l ${k8s_lv_size}
	else
		sudo lvcreate -y --wipesignatures y -n kubernetes vgpaas -L ${k8s_lv_size}
	fi

set +e
	umount $(df -h | grep kubernetes | awk '{print $6}') -f
set -e
	sudo mkfs -t xfs /dev/vgpaas/kubernetes
	echo "begin to mount kubernetes..."
	sudo mkdir -p /mnt/paas/kubernetes
	echo "/dev/vgpaas/kubernetes  /mnt/paas/kubernetes  xfs  noatime  0 0" | sudo tee -a /etc/fstab >/dev/null
	sudo mount /mnt/paas/kubernetes
	move_kubelet="/mnt/paas/kubernetes"


	if [[ -n "${move_kubelet}" ]]; then
		# Move /var/lib/kubelet to e.g. /mnt
		# (the backing for empty-dir volumes can use a lot of space!)
		if [[ -d /var/lib/kubelet ]]; then
			sudo mv /var/lib/kubelet ${move_kubelet}/
		fi
		sudo mkdir -p ${move_kubelet}/kubelet
		sudo ln -s ${move_kubelet}/kubelet /var/lib/kubelet
	fi

	# 4. convert volumes to a thin pool and a storage location for metadata for the thin pool
	echo "Step four. Convert volumes to a thin pool..."
	sudo lvconvert -y \
		--zero n \
		-c 512K \
		--thinpool vgpaas/thinpool \
		--poolmetadata vgpaas/thinpoolmeta

	# 5. configure autoextension of thin pools via an lvm profile
	echo "Step five. Configure autoextension of thin pools..."
	sudo mkdir -p /etc/lvm/profile/
	sudo sh -c "cat > /etc/lvm/profile/vgpaas-thinpool.profile << EOF
activation {
  thin_pool_autoextend_threshold=100
  thin_pool_autoextend_percent=0
}
EOF"

	# 6. app the lvm profile
	echo "Step six. Applicate the lvm profile..."
	sudo lvchange --metadataprofile vgpaas-thinpool vgpaas/thinpool

	# 7. enable monitoring for logical volumes on your host. Without this step, automatic extension will not occur even in the presence of the LVM profile
	echo "Step seven. Enable monitoring for logical volumes..."
	sudo lvs -o+seg_monitor

	# 8. set DOCKER_OPTS
set +e
	sudo mkdir -p /etc/docker/
set -e
	sudo sh -c "cat > /etc/docker/daemon.json << EOF
{
    \"storage-driver\": \"devicemapper\",
    \"storage-opts\": [
    \"dm.thinpooldev=/dev/mapper/vgpaas-thinpool\",
    \"dm.use_deferred_removal=true\",
    \"dm.use_deferred_deletion=true\"
    ],
    \"log-driver\": \"json-file\",
    \"log-opts\": {
      \"max-size\": \"10m\"
     }
}
EOF"
}

function backup_images()
{
	echo "begin to backup system images..."
	mkdir -p ./backup
	docker save -o ./backup/cfe-kube-dnsmasq-amd64.tar cfe-kube-dnsmasq-amd64:5.10.3
	docker save -o ./backup/cfe-kubedns-amd64.tar cfe-kubedns-amd64:5.10.3
	docker save -o ./backup/cfe-exechealthz-amd64.tar cfe-exechealthz-amd64:5.10.3
	docker save -o ./backup/pause.tar cfe-pause:5.10.3
	docker save -o ./backup/euleros.tar euleros:2.2.5
	docker save -o ./backup/canal-agent-1.tar canal-agent:1.0.RC2.SPC1.B050
	docker save -o ./backup/canal-agent-2.tar canal-agent:latest
	echo "end backup..."
}

function clean_envs()
{
	echo "begin to clean envs..."
set +e
	docker stop $(docker ps | awk '{print $1}')
	sleep 3
	umount $(df -h | grep kubernetes | awk '{print $6}') -f
	sleep 2
	umount $(df -h | grep kubernetes | awk '{print $6}') -f
	result=$(df -h | grep kubernetes | awk '{print $6}')
	echo "$result"
set -e
	rm -rf /mnt/paas/kubernetes
	rm -rf /var/lib/kubelet
	vgremove vgpaas -f
	echo "env clean..."
}

function load_images()
{
	systemctl start docker
        docker load -i ./backup/cfe-kube-dnsmasq-amd64.tar
        docker load -i ./backup/cfe-kubedns-amd64.tar
        docker load -i ./backup/cfe-exechealthz-amd64.tar
        docker load -i ./backup/pause.tar
        docker load -i ./backup/euleros.tar
        docker load -i ./backup/canal-agent-1.tar
        docker load -i ./backup/canal-agent-2.tar
}

DOCKER_THINPOOL=${DOCKER_THINPOOL-:"vgpaas/50%VG"}
KUBERNETES_LV=${KUBERNETES_LV-:"vgpaas/50%VG"}

sleep 2
prepare_system_disk
