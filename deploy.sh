#!/bin/bash

juju destroy-model charmed-openstack --force

echo "Starting deployment..."

juju add-model -c maas-cloud-default charmed-openstack
juju switch maas-cloud-default:charmed-openstack
juju deploy ./bundle.yaml

echo 'Waiting for deployment to settle...'

until [ `juju status |grep -E "allocating|executing" |wc -l` -eq 0 ]
do
  sleep 10
done

echo "Unsealing Vault..."

juju run -u vault/leader '
export VAULT_ADDR="http://127.0.0.1:8200"
vault operator init -key-shares=5 -key-threshold=3 | tee /root/init.txt
UNSEAL_KEYS=$(grep "Unseal Key" /root/init.txt | awk {"print \$4"} | head -3)
for UK in $UNSEAL_KEYS; do vault operator unseal $UK; done
export VAULT_TOKEN=$(grep "Initial Root Token" /root/init.txt | awk {"print \$4"})
vault token create -ttl=10m | tee /root/token.txt
TOKEN=$(grep token /root/token.txt | awk {"print \$2"} | head -1)
echo $TOKEN > /root/token.txt
'
sleep 10

TOKEN=$(juju run -u vault/leader 'cat /root/token.txt')
juju run-action --wait vault/leader authorize-charm token=$TOKEN
juju run-action --wait vault/leader generate-root-ca

echo "Vault unsealed."
echo 'Waiting for Keystone to become active...'

until [ `juju status |grep "executing" |wc -l` -eq 0 ]
do
  sleep 10
done

echo "Configuring network..."

source openrc
openstack network create --external --provider-network-type flat --provider-physical-network physnet1 ext_net
openstack subnet create --network ext_net --no-dhcp --gateway 172.27.99.254 --subnet-range 172.27.98.0/23 --allocation-pool start=172.27.99.101,end=172.27.99.200 ext_subnet
openstack network create int_net
openstack subnet create --network int_net --dns-nameserver 172.27.99.254 --gateway 192.168.123.1 --subnet-range 192.168.123.0/24 --allocation-pool start=192.168.123.2,end=192.168.123.254 int_subnet
openstack router create provider-router
openstack router set --external-gateway ext_net provider-router
openstack router add subnet provider-router int_subnet

echo "Creating image..."

#create image
openstack image create --public --container-format bare --disk-format qcow2 --file ~/ob96-demos/openstack/cloud-images/cirros-0.6.1-x86_64-disk.raw cirros

#create flavor
openstack flavor create --ram 512 --disk 5 --ephemeral 10 m1.teeny

#create keypair
openstack keypair create --public-key ~/ob96-demos/openstack/cloud-keys/id_mykey.pub mykey

echo "Configuring security groups..."

#configure security groups
for i in $(openstack security group list | awk '/default/{ print $2 }'); do
openstack security group rule create $i --protocol icmp --remote-ip 0.0.0.0/0;
openstack security group rule create $i --protocol tcp --remote-ip 0.0.0.0/0 --dst-port 22;
done

#get dashboard IP and password
IP=$(juju status --format=yaml openstack-dashboard | grep public-address | awk '{print $2}' | head -1)
PASSWORD=$(juju run --unit keystone/leader leader-get admin_passwd)

echo http://$IP/horizon
echo User Name: admin
echo Password: $PASSWORD
echo Domain: admin_domain
