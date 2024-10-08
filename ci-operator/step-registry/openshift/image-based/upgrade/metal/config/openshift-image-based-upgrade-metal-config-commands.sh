#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
export PS4='+ $(date "+%T.%N") \011'

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")

instance_ip=$(cat ${SHARED_DIR}/public_address)
host=$(cat ${SHARED_DIR}/ssh_user)

ssh_host_ip="$host@$instance_ip"

if ! test -f "${SHARED_DIR}/remote_workdir"; then
  workdir="/home/${host}/workdir-seed-$(date +%Y%m%d)"

  echo "${workdir}" >> "${SHARED_DIR}/remote_workdir"
fi

remote_workdir=$(cat "${SHARED_DIR}/remote_workdir")

ssh "${SSHOPTS[@]}" "${ssh_host_ip}" "mkdir -p ${remote_workdir}"

cat <<EOF > ${SHARED_DIR}/install.sh
#!/bin/bash
set -euo pipefail

function dnf_install_retry {
  packages=(\$@)
  echo "Installing packages with retry"

  for _ in \$(seq 3) ; do
    sudo dnf clean -y all # clean the cache

    # shellcheck disable=SC2086
    sudo dnf install -y \${packages[*]} && return 0
     
    rc=\$? # save the return code

    if [ \$rc -ne 0 ]
    then
      echo "Failed to run dnf install, retrying"
    fi
  done

  if [ \$rc -ne 0 ]
  then
    echo "Failed to run dnf install after 3 attempts"
  fi

  return "\${rc}"
}

sudo subscription-manager config --rhsm.manage_repos=1 --rhsmcertd.disable=redhat-access-insights

if ! sudo subscription-manager status >&/dev/null; then
    sudo subscription-manager register \
        --org="\$(cat /tmp/subscription-manager-org)" \
        --activationkey="\$(cat /tmp/subscription-manager-act-key)"
fi

sudo subscription-manager repos \
--enable "rhel-9-for-$(uname -m)-appstream-rpms" \
--enable "rhel-9-for-$(uname -m)-baseos-rpms" \
--enable "rhocp-4.14-for-rhel-9-$(uname -m)-rpms"

cd ${remote_workdir}

sudo dnf -y copr enable nmstate/nmstate-git
dnf_install_retry nmstate virt-install virt-manager libvirt-nss openshift-clients cockpit-machines golang jq sos podman skopeo

sudo systemctl start libvirtd
sudo systemctl enable libvirtd

sudo usermod -a -G libvirt ec2-user

# Check for git
if ! command -v git &> /dev/null
then
    dnf_install_retry git
fi

git clone https://github.com/rh-ecosystem-edge/ib-orchestrate-vm.git
cd ib-orchestrate-vm && git checkout ${IB_ORCHESTRATE_VM_REF}

EOF

chmod +x ${SHARED_DIR}/install.sh
scp "${SSHOPTS[@]}" ${SHARED_DIR}/install.sh $ssh_host_ip:$remote_workdir

scp "${SSHOPTS[@]}" \
    /var/run/rhsm/subscription-manager-org \
    /var/run/rhsm/subscription-manager-act-key \
    "${ssh_host_ip}:/tmp"

ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/install.sh"

# Configure NSS to use libvirt guest names as hostnames
# This is the default configuration with libvirt_guest added to the hosts line
cat <<EOF > ${SHARED_DIR}/nsswitch.conf

# Configure NSS to use libvirt guest names as hostnames
# This is the default configuration with libvirt_guest added to the hosts line
cat <<EOF > ${SHARED_DIR}/nsswitch.conf
# Generated by authselect on Wed Nov  8 07:43:00 2023
# Do not modify this file manually.

# If you want to make changes to nsswitch.conf please modify
# /etc/authselect/user-nsswitch.conf and run 'authselect apply-changes'.
#
# Note that your changes may not be applied as they may be
# overwritten by selected profile. Maps set in the authselect
# profile takes always precedence and overwrites the same maps
# set in the user file. Only maps that are not set by the profile
# are applied from the user file.
#
# For example, if the profile sets:
#     passwd: sss files
# and /etc/authselect/user-nsswitch.conf contains:
#     passwd: files
#     hosts: files dns
# the resulting generated nsswitch.conf will be:
#     passwd: sss files # from profile
#     hosts: files dns  # from user file

passwd:     files sss systemd
group:      files sss systemd
netgroup:   sss files
automount:  sss files
services:   sss files

# Included from /etc/authselect/user-nsswitch.conf

#
# /etc/nsswitch.conf
#
# Name Service Switch config file. This file should be
# sorted with the most-used services at the beginning.
#
# Valid databases are: aliases, ethers, group, gshadow, hosts,
# initgroups, netgroup, networks, passwd, protocols, publickey,
# rpc, services, and shadow.
#
# Valid service provider entries include (in alphabetical order):
#
#       compat                  Use /etc files plus *_compat pseudo-db
#       db                      Use the pre-processed /var/db files
#       dns                     Use DNS (Domain Name Service)
#       files                   Use the local files in /etc
#       hesiod                  Use Hesiod (DNS) for user lookups
#
# Commonly used alternative service providers (may need installation):
#
#       ldap                    Use LDAP directory server
#       myhostname              Use systemd host names
#       mymachines              Use systemd machine names
#       mdns*, mdns*_minimal    Use Avahi mDNS/DNS-SD
#       resolve                 Use systemd resolved resolver
#       sss                     Use System Security Services Daemon (sssd)
#       systemd                 Use systemd for dynamic user option
#       winbind                 Use Samba winbind support
#       wins                    Use Samba wins support
#       wrapper                 Use wrapper module for testing
#
# Notes:
#
# 'sssd' performs its own 'files'-based caching, so it should generally
# come before 'files'.
#
# WARNING: Running nscd with a secondary caching service like sssd may
#          lead to unexpected behaviour, especially with how long
#          entries are cached.
#
# Installation instructions:
#
# To use 'db', install the appropriate package(s) (provide 'makedb' and
# libnss_db.so.*), and place the 'db' in front of 'files' for entries
# you want to be looked up first in the databases, like this:
#
# passwd:    db files
# shadow:    db files
# group:     db files

# In order of likelihood of use to accelerate lookup.
shadow:     files
hosts:      files libvirt_guest dns myhostname

aliases:    files
ethers:     files
gshadow:    files
# Allow initgroups to default to the setting for group.
# initgroups: files
networks:   files dns
protocols:  files
publickey:  files
rpc:        files
EOF

scp "${SSHOPTS[@]}" ${SHARED_DIR}/nsswitch.conf $ssh_host_ip:${remote_workdir}/nsswitch.conf

ssh "${SSHOPTS[@]}" $ssh_host_ip "sudo mv ${remote_workdir}/nsswitch.conf /etc/nsswitch.conf"

# Upload the pull secrets
LCA_PULL_SECRET_FILE="/var/run/pull-secret/.dockerconfigjson"
CLUSTER_PULL_SECRET_FILE="${CLUSTER_PROFILE_DIR}/pull-secret"
PULL_SECRET=$(cat ${CLUSTER_PULL_SECRET_FILE} ${LCA_PULL_SECRET_FILE} | jq -cs '.[0] * .[1]') # Merge the pull secrets to get everything we need
BACKUP_SECRET_FILE="/var/run/ibu-backup-secret/.backup-secret"
BACKUP_SECRET=$(jq -c . ${BACKUP_SECRET_FILE})

# Save the pull secrets
echo -n "${PULL_SECRET}" > ${SHARED_DIR}/.pull_secret.json
echo -n "${BACKUP_SECRET}" > ${SHARED_DIR}/.backup_secret.json

echo "Transferring pull secrets..."
scp "${SSHOPTS[@]}" ${SHARED_DIR}/.pull_secret.json $ssh_host_ip:$remote_workdir
scp "${SSHOPTS[@]}" ${SHARED_DIR}/.backup_secret.json $ssh_host_ip:$remote_workdir

rm ${SHARED_DIR}/.pull_secret.json ${SHARED_DIR}/.backup_secret.json

echo "${remote_workdir}/.pull_secret.json" >> "${SHARED_DIR}/pull_secret_file"
echo "${remote_workdir}/.backup_secret.json" >> "${SHARED_DIR}/backup_secret_file"
