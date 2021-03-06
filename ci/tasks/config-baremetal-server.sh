#!/usr/bin/env bash
set -e -x

# Config bosh with bmp server
echo "installing bosh CLI"
gem install bosh_cli --no-ri --no-rdo c

echo "using bosh CLI version..."
bosh version

echo "login director..."
bosh -n target ${BM_DIRECTOR_IP}
bosh login admin admin
publicIp=`bosh vms|grep 'bmp-server/0' | awk '{print $11}'`
echo "public ip is" $publicIp

USERNAME=${SL_USERNAME/@/%40}
url='https://'"${USERNAME}"':'"${SL_API_KEY}"'@api.softlayer.com/rest/v3/SoftLayer_Account/getVirtualGuests?objectMask=mask[primaryBackendIpAddress,operatingSystem.passwords.password]&objectFilter={"virtualGuests":{"primaryIpAddress":{"operation":"'"${publicIp}"'"}}}'
result_file=result.file
curl -g $url > $result_file
privateIp=`grep -oP '(?<="primaryBackendIpAddress":")[^"]*' $result_file`
password=`grep -oP '(?<="password":")[^"]*' $result_file`
deployment_dir="${PWD}/bps-deployment"
echo $privateIp > $deployment_dir/bmp-server-info
echo $password >> $deployment_dir/bmp-server-info
cat $deployment_dir/bmp-server-info

# temporary: reinstall perl lib dependency
reinstall_file=reinstall.sh
cat > "${reinstall_file}"<<EOF
#!/bin/bash
set -e
wget http://search.cpan.org/CPAN/authors/id/M/MO/MONS/XML-Hash-LX-0.0603.tar.gz
tar zxvf XML-Hash-LX-*.tar.gz
pushd XML-Hash-LX-*
  perl Makefile.PL
  make
  make install
popd
EOF
chmod +x $reinstall_file

sudo apt-get -y install expect
set timeout 30
/usr/bin/env expect<<EOF
spawn scp -o StrictHostKeyChecking=no $reinstall_file root@$privateIp:/root/
expect "*?assword:*"
exp_send "$password\r"

spawn ssh -o StrictHostKeyChecking=no root@$privateIp
expect "*?assword:*"
exp_send "$password\r"
sleep 5
send "./$reinstall_file | tee ${reinstall_file}.log\r"
sleep 120
expect eof
EOF

# create netboot image and stemcell for bmp server
create_image_file=create_bmp_server_image.sh
cat > "${create_image_file}"<<EOF
#!/bin/bash
set -e
#create default netboot image
lsdef -t osimage -z ubuntu14.04.3-x86_64-netboot-compute | tee osimage.log
cat osimage.log | sed 's/^[^ ]\+:/bps-netboot-ixgbe-lon02:/' | mkdef -z
sleep 3
genimage -n ixgbe bps-netboot-ixgbe-lon02
sleep 3
packimage bps-netboot-ixgbe-lon02
sleep 3

#create baremetal stemcell
cd /var/vcap/store/baremetal-provision-server/stemcells/
mkdir bosh-stemcell-0.3-softlayer-baremetal
cd bosh-stemcell-0.3-softlayer-baremetal
wget https://s3.amazonaws.com/dev-bosh-softlayer-cpi-stemcells/bosh-stemcell-0.3-softlayer-baremetal.fsa
cp /var/vcap/packages/baremetal-provision-server/scripts/stemcell_template/* .
EOF
chmod +x $create_image_file

set timeout 30
/usr/bin/env expect<<EOF
spawn scp -o StrictHostKeyChecking=no $create_image_file root@$privateIp:/root/
expect "*?assword:*"
exp_send "$password\r"

spawn ssh -o StrictHostKeyChecking=no root@$privateIp
expect "*?assword:*"
exp_send "$password\r"
sleep 5
send "./$create_image_file | tee ${create_image_file}.log\r"
sleep 1200
expect eof
EOF

# update bmp server hostname and xcat passwd table
/usr/bin/env expect<<EOF
spawn ssh -o StrictHostKeyChecking=no root@$privateIp
expect "*?assword:*"
exp_send "$password\r"
sleep 5
send "sed -i '/127.0.0.1/s/$/.softlayer.com/' /etc/hosts\r"
sleep 3
send "chtab key=system passwd.username=root passwd.password=$password\r"
sleep 5
expect eof
EOF

# config director with bmp server
cpi_file=cpi.json
cat > "${cpi_file}" << EOF
{"cloud":{"plugin":"softlayer","properties":{"softlayer":{"username":"${SL_USERNAME}","apiKey":"${SL_API_KEY}"},"agent":{"ntp":[],"blobstore":{"provider":"dav","options":{"endpoint":"http://127.0.0.1:25250","user":"agent","password":"agent"}},"mbus":"nats://nats:nats@127.0.0.1:4222"},"baremetal":{"username":"admin","password":"admin","endpoint":"http://${privateIp}:8080"}}}}
EOF

/usr/bin/env expect<<EOF
spawn scp -o StrictHostKeyChecking=no $cpi_file root@${BM_DIRECTOR_IP}:/var/vcap/data/jobs/softlayer_cpi/a53b4520362228e32052e95f1cb1a5d8bfd06059-52c1fc5bca79f647ee29f87cf658b6d5843d5656/config/
expect "*?assword:*"
exp_send "${BM_DIRECTOR_PASSWORD}\r"
expect eof
EOF

# verify bmp server using bmp cli tool
bmp_server=`cat ${PWD}/bps-deployment/bmp-server-info | sed -n '1p'`
bm_deployment_file=deployment.yml
cat > "$bm_deployment_file"<<EOF
---
name: bps-pipeline
resource_pools:

- name: coreNode-bm
  size: 1
  cloud_properties:
    bosh_ip: ${BM_DIRECTOR_IP}
    datacenter: ${SL_DATACENTER}
    domain: bluemix.com
    name_prefix: bm-pipeline
    server_spec:
      cores: 4
      memory: 4
      max_port_speed: 100
      public_vlan_id: 524956
      private_vlan_id: 524954
      hourly: true
    baremetal: true
    bm_stemcell: ${BM_STEMCELL}
    bm_netboot_image: ${BM_NETBOOT_IMAGE}
EOF

tar -zxvf bosh-softlayer-tools/bosh-softlayer-tools-*.tgz
mv bmp /usr/local/bin
echo "{}" > $HOME/.bmp_config
export NON_VERBOSE=true

echo "set bmp target to bmp server..."
bmp target -t http://$bmp_server:8080

echo "login bmp server..."
bmp login -u admin -p admin

echo "check bmp server status..."
bmp status

echo "return available baremetals..."
bmp bms -d $bm_deployment_file

echo "return stemcells..."
bmp stemcells

echo "return tasks..."
bmp tasks

echo "return all packages..."
bmp sl --packages

echo "return options of one package..."
bmp sl --package-options=255