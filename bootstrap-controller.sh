# This script bootstraps a controller node on UTSA's chameleon cloud.
# It takes all the actions necessary for the deployment of the 
# controller according the the Openstack Ansible Deployment(OSD) 
# architecture (https://github.com/openstack/openstack-ansible).
# This script does not deploy a highly available controller node.
# The container affinity is set to 1 for the database, messaging
# queue, and API services.
# Auther(s):
# Miguel Alex Cantu (miguel.cantu@rackspace.com)
# Most content is from https://github.com/openstack/openstack-ansible/blob/master/scripts/bootstrap-aio.sh

# Usage:
# ./bootstrap-controller.sh <mgmt-ip>

if [ $# -lt 4 ]
then
	echo "./bootstrap-controller.sh <mgmt-ip-controller> <container-net> <tunnel-net> <storage-net>"
	exit
fi

# For debugging only
set -e -u -x

#export ETH0_NETMASK="$(ifconfig eth0 | grep Mask | awk -F ':' '{print $4}')"
export ETH0_NETMASK="255.255.252.0"
export ETH0_GATEWAY="$(ip r | grep default | awk '{print $3}')"

export MANAGEMENT_IP=$1
#export MANAGEMENT_IP_COMPUTE1=$2
#export MANAGEMENT_IP_COMPUTE2=$3
#export MANAGEMENT_IP_COMPUTE3=$4
CONTAINER_NETWORK=$2
export CONTAINER_NETWORK=$(echo $CONTAINER_NETWORK | sed 's/\//\\\//g')
TUNNEL_NETWORK=$3
export TUNNEL_NETWORK=$(echo $TUNNEL_NETWORK | sed 's/\//\\\//g')
STORAGE_NETWORK=$4
export STORAGE_NETWORK=$(echo $STORAGE_NETWORK | sed 's/\//\\\//g')
export DEFAULT_PASSWORD="openstack"
export OPENSTACK_ANSIBLE_TAG="11.2.3"

export ADMIN_PASSWORD=${ADMIN_PASSWORD:-$DEFAULT_PASSWORD}
export PUBLIC_INTERFACE=${PUBLIC_INTERFACE:-$(ip route show | awk '/default/ { print $NF }')}

# If br-mgmt bridge is up already, use that for public address and interface.
if grep "br-mgmt" /proc/net/dev > /dev/null;then
  export PUBLIC_INTERFACE="br-mgmt"
  export PUBLIC_ADDRESS=${PUBLIC_ADDRESS:-$(ip -o -4 addr show dev ${PUBLIC_INTERFACE} | awk -F '[ /]+' '/global/ {print $4}' | head -n 1)}
else 
  export PUBLIC_ADDRESS=${PUBLIC_ADDRESS:-$(ip -o -4 addr show dev ${PUBLIC_INTERFACE} | awk -F '[ /]+' '/global/ {print $4}')}
fi

UBUNTU_RELEASE=$(lsb_release -sc)
UBUNTU_REPO=${UBUNTU_REPO:-$(awk "/^deb .*ubuntu\/? ${UBUNTU_RELEASE} main/ {print \$2; exit}" /etc/apt/sources.list)}
UBUNTU_SEC_REPO=${UBUNTU_SEC_REPO:-$(awk "/^deb .*ubuntu\/? ${UBUNTU_RELEASE}-security main/ {print \$2; exit}" /etc/apt/sources.list)}

# Ensure that the current kernel can support vxlan
if ! modprobe vxlan; then
  echo "VXLAN support is required for this to work. And the Kernel module was not found."
  echo "This build will not work without it."
  exit
fi

# Set base DNS to google, ensuring consistent DNS in different environments
if [ ! "$(grep -e '^nameserver 8.8.8.8' -e '^nameserver 8.8.4.4' /etc/resolv.conf)" ];then
  echo -e '\n# Adding google name servers\nnameserver 8.8.8.8\nnameserver 8.8.4.4' | tee -a /etc/resolv.conf
fi

# Ensure that the https apt transport is available before doing anything else
apt-get update && apt-get install -y apt-transport-https < /dev/null


# Set the host repositories to only use the same ones, always, for the sake of consistency.
cat > /etc/apt/sources.list <<EOF
# Base repositories
deb ${UBUNTU_REPO} ${UBUNTU_RELEASE} main restricted universe multiverse
# Updates repositories
deb ${UBUNTU_REPO} ${UBUNTU_RELEASE}-updates main restricted universe multiverse
# Backports repositories
deb ${UBUNTU_REPO} ${UBUNTU_RELEASE}-backports main restricted universe multiverse
# Security repositories
deb ${UBUNTU_SEC_REPO} ${UBUNTU_RELEASE}-security main restricted universe multiverse
EOF

# Update the package cache
apt-get update

# Install required packages
apt-get install -y bridge-utils \
                   build-essential \
                   curl \
                   ethtool \
                   git-core \
                   ipython \
                   linux-image-extra-$(uname -r) \
                   lvm2 \
                   python2.7 \
                   python-dev \
                   tmux \
                   vim \
                   vlan \
                   xfsprogs < /dev/null

# Flush all the iptables rules.
# Flush all the iptables rules.
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Ensure that sshd permits root login, or ansible won't be able to connect
if grep "^PermitRootLogin" /etc/ssh/sshd_config > /dev/null; then
  sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
else
  echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
fi

# Create /opt if it doesn't already exist
if [ ! -d "/opt" ];then
  mkdir /opt
fi

# Clone openstack-ansible playbooks if not already done so.
if [ ! -d "/opt/openstack-ansible" ];then
  git clone https://github.com/openstack/openstack-ansible.git /opt/openstack-ansible
  pushd /opt/openstack-ansible
    git checkout $OPENSTACK_ANSIBLE_TAG
  popd
fi

# Remove the pip directory if its found
if [ -d "${HOME}/.pip" ];then
  rm -rf "${HOME}/.pip"
fi

# Install pip
# if pip is already installed, don't bother doing anything
if [ ! "$(which pip)" ]; then

  # if GET_PIP_URL is set, then just use it
  if [ -z "${GET_PIP_URL:-}" ]; then

    # Find and use an available get-pip download location.
    if curl --silent https://bootstrap.pypa.io/get-pip.py; then
      export GET_PIP_URL='https://bootstrap.pypa.io/get-pip.py'
    elif curl --silent https://raw.github.com/pypa/pip/master/contrib/get-pip.py; then
      export GET_PIP_URL='https://raw.github.com/pypa/pip/master/contrib/get-pip.py'
    else
      echo "A suitable download location for get-pip.py could not be found."
      exit
    fi
  fi

  # Download and install pip
  curl ${GET_PIP_URL} > /opt/get-pip.py
  python2 /opt/get-pip.py || python /opt/get-pip.py
fi

# Install pip requirements
pip install pycrypto netaddr

# Make the system key used for bootstrapping self
if [ ! -d /root/.ssh ];then
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
fi

# Ensure that the ssh key exists and is an authorized_key
key_path="${HOME}/.ssh"
key_file="${key_path}/id_rsa"

# Ensure that the .ssh directory exists and has the right mode
if [ ! -d ${key_path} ]; then
  mkdir -p ${key_path}
  chmod 700 ${key_path}
fi
if [ ! -f "${key_file}" -a ! -f "${key_file}.pub" ]; then
  rm -f ${key_file}*
  ssh-keygen -t rsa -f ${key_file} -N ''
fi

# Ensure that the public key is included in the authorized_keys
# for the default root directory and the current home directory
key_content=$(cat "${key_file}.pub")
if ! grep -q "${key_content}" ${key_path}/authorized_keys; then
  echo "${key_content}" | tee -a ${key_path}/authorized_keys
fi

# Copy aio network config into place.
#if [ ! -d "/etc/network/interfaces.d" ];then
#  mkdir -p /etc/network/interfaces.d/
#fi
#
## Copy the basic aio network interfaces over
#cp -R controller-interfaces.cfg.template /etc/network/interfaces.d/controller-interfaces.cfg
#
## Modify the file to match the IPs given by the user.
#sed -i "s/ETH0IP/$PUBLIC_ADDRESS/g" /etc/network/interfaces.d/controller-interfaces.cfg

#sed -i "s/MGMTIP/$MANAGEMENT_IP/g" /etc/network/interfaces.d/controller-interfaces.cfg
#sed -i "s/ETH0NETMASK/$ETH0_NETMASK/g" /etc/network/interfaces.d/controller-interfaces.cfg
#sed -i "s/ETH0GATEWAY/$ETH0_GATEWAY/g" /etc/network/interfaces.d/controller-interfaces.cfg
#
#cp -R interfaces.template /etc/network/interfaces

# Bring up the new interfaces
for i in $(awk '/^iface/ {print $2}' /etc/network/interfaces.d/controller-interfaces.cfg); do
    /sbin/ifup $i || true
done

# Instead of moving the AIO files in place, it will move our custom
# configs in place.
cp -R /opt/OSCAR/openstack_deploy /etc/openstack_deploy/
cp /opt/OSCAR/openstack_deploy/openstack_user_config.yml.template /etc/openstack_deploy/openstack_user_config.yml

#Substitue the IPs in the openstack_user_config.yml with the user-defined IPs
sed -i "s/MGMTIP/$MANAGEMENT_IP/g" /etc/openstack_deploy/openstack_user_config.yml

#Adding compute nodes and their management ip's from management_ips file in openstack_user_config.yml
# ***** Needs some testing 

break_var=$(sed '1,/computes:/d;/- /d' /etc/oscar/oscar.conf | sed '1,/computes:/d;/- /d' /etc/oscar/oscar.conf | sed '1!d')

computes_count=$(sed "1,/computes:/d;/$break_var/,/^\s*$/d" /etc/oscar/oscar.conf | wc -l)

#echo $computes_count

sed "1,/computes:/d;/$break_var/,/^\s*$/d" /etc/oscar/oscar.conf

management_ip=$MANAGEMENT_IP
management_ip_base=$(echo $management_ip | cut -d"." -f1-3)
#echo $management_ip_base
for ((i=1; i<=computes_count; i++)); do
   line=$management_ip_base"."$(( 100 + $i ))
   sed -i 's/.*compute_hosts:.*/&\n   compute'$i':/' /etc/openstack_deploy/openstack_user_config.yml
   sed -i 's/.*compute'$i':.*/&\n      ip: '$line'/' /etc/openstack_deploy/openstack_user_config.yml
   #echo $management_ip_base"."$(( 100 + $i ))
done




#compute_count=1
#while IFS='' read -r line || [[ -n "$line" ]]; do
#   sed -i 's/.*compute_hosts:.*/&\n   compute'$compute_count':/' /etc/openstack_deploy/openstack_user_config.yml
#   sed -i 's/.*compute'$compute_count':.*/&\n      ip: '$line'/' /etc/openstack_deploy/openstack_user_config.yml
#   compute_count=$(($compute_count + 1))
#done < "/opt/OSCAR/management_ips"
#sed -i "s/COMPUTE1IP/$MANAGEMENT_IP_COMPUTE1/g" /etc/openstack_deploy/openstack_user_config.yml
#sed -i "s/COMPUTE2IP/$MANAGEMENT_IP_COMPUTE2/g" /etc/openstack_deploy/openstack_user_config.yml
#sed -i "s/COMPUTE3IP/$MANAGEMENT_IP_COMPUTE3/g" /etc/openstack_deploy/openstack_user_config.yml

# Populate the cidr_networks in the /etc/openstack_deploy/openstack_user_config.yml
sed -i "s/CONTAINER_NETWORK/$CONTAINER_NETWORK/g" /etc/openstack_deploy/openstack_user_config.yml
sed -i "s/TUNNEL_NETWORK/$TUNNEL_NETWORK/g" /etc/openstack_deploy/openstack_user_config.yml
sed -i "s/STORAGE_NETWORK/$STORAGE_NETWORK/g" /etc/openstack_deploy/openstack_user_config.yml 

# Ensure the conf.d directory exists
if [ ! -d "/etc/openstack_deploy/conf.d" ];then
  mkdir -p "/etc/openstack_deploy/conf.d"
fi

# Move the user_variables file from /opt/openstack-ansible/etc/openstack_deploy/ to /etc/openstack_deploy
cp /opt/openstack-ansible/etc/openstack_deploy/user_variables.yml /etc/openstack_deploy/user_variables.yml
cp /opt/openstack-ansible/etc/openstack_deploy/user_secrets.yml /etc/openstack_deploy/user_secrets.yml

# Generate the passwords
/opt/OSCAR/scripts/pw-token-gen.py --file /etc/openstack_deploy/user_secrets.yml

#change the generated passwords for the OpenStack (admin)
sed -i "s/keystone_auth_admin_password:.*/keystone_auth_admin_password: ${ADMIN_PASSWORD}/" /etc/openstack_deploy/user_secrets.yml
sed -i "s/external_lb_vip_address:.*/external_lb_vip_address: ${PUBLIC_ADDRESS}/" /etc/openstack_deploy/openstack_user_config.yml

# TODO: Maybe save this for some later time. - Alex
#if [ ${DEPLOY_CEILOMETER} == "yes" ]; then
#  # Install mongodb on the aio1 host
#  apt-get install mongodb-server mongodb-clients python-pymongo -y < /dev/null
#  # Change bind_ip to management ip
#  sed -i "s/^bind_ip.*/bind_ip = $MONGO_HOST/" /etc/mongodb.conf
#  # Asserting smallfiles key
#  sed -i "s/^smallfiles.*/smallfiles = true/" /etc/mongodb.conf
#  service mongodb restart
#
#  # Wait for mongodb to restart
#  for i in {1..12}; do
#    mongo --host $MONGO_HOST --eval ' ' && break
#    sleep 5
#  done
#  #Adding the ceilometer database
#  mongo --host $MONGO_HOST --eval '
#    db = db.getSiblingDB("ceilometer");
#    db.addUser({user: "ceilometer",
#    pwd: "ceilometer",
#    roles: [ "readWrite", "dbAdmin" ]})'
#
#  # change the generated passwords for mongodb access
#  sed -i "s/ceilometer_container_db_password:.*/ceilometer_container_db_password: ceilometer/" /etc/openstack_deploy/user_secrets.yml
#  # Change the Ceilometer user variables necessary for deployment
#  sed -i "s/ceilometer_db_ip:.*/ceilometer_db_ip: ${MONGO_HOST}/" /etc/openstack_deploy/user_variables.yml
#  # Enable Ceilometer for Swift
#  if [ ${DEPLOY_SWIFT} == "yes" ]; then
#    sed -i "s/swift_ceilometer_enabled:.*/swift_ceilometer_enabled: True/" /etc/openstack_deploy/user_variables.yml
#  fi
#  # Enable Ceilometer for other OpenStack Services
#  if [ ${DEPLOY_OPENSTACK} == "yes" ]; then
#    for svc in cinder glance heat nova; do
#      sed -i "s/${svc}_ceilometer_enabled:.*/${svc}_ceilometer_enabled: True/" /etc/openstack_deploy/user_variables.yml
#    done
#  fi
#  echo 'tempest_service_available_ceilometer: true' | tee -a /etc/openstack_deploy/user_variables.yml
#fi

## Service region set
#echo "service_region: ${SERVICE_REGION}" | tee -a /etc/openstack_deploy/user_variables.yml
#
## Virt type set
#echo "nova_virt_type: ${NOVA_VIRT_TYPE}" | tee -a /etc/openstack_deploy/user_variables.yml
#
#


## Set the running kernel as the required kernel
echo "required_kernel: $(uname --kernel-release)" | tee -a /etc/openstack_deploy/user_variables.yml

## Set the Ubuntu apt repository used for containers to the same as the host
echo "lxc_container_template_main_apt_repo: ${UBUNTU_REPO}" | tee -a /etc/openstack_deploy/user_variables.yml
echo "lxc_container_template_security_apt_repo: ${UBUNTU_SEC_REPO}" | tee -a /etc/openstack_deploy/user_variables.yml

echo "------DONE!!------"
