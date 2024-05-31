#!/bin/bash
set -e
DEBUG="YES"
if [ "${DEBUG}" == "NO" ]; then
  trap "cleanup $? $LINENO" EXIT
fi

function cleanup {
  if [ "$?" != "0" ]; then
    echo "PLAYBOOK FAILED. See /var/log/stackscript.log for details."
    rm ${HOME}/.ssh/id_ansible_ed25519{,.pub}
    destroy
    exit 1
  fi
}

# constants
readonly ROOT_PASS=$(sudo cat /etc/shadow | grep root)
readonly LINODE_PARAMS=($(curl -sH "Authorization: Bearer ${TOKEN_PASSWORD}" "https://api.linode.com/v4/linode/instances/${LINODE_ID}" | jq -r .type,.region,.image))
readonly TAGS=$(curl -sH "Authorization: Bearer ${TOKEN_PASSWORD}" "https://api.linode.com/v4/linode/instances/${LINODE_ID}" | jq -r .tags)
readonly VARS_PATH="./group_vars/apache-cassandra/vars"

# utility functions
function destroy {
  if [ -n "${DISTRO}" ] && [ -n "${DATE}" ]; then
    ansible-playbook destroy.yml --extra-vars "instance_prefix=${DISTRO}-${DATE}"
  else
    ansible-playbook destroy.yml
  fi
}

function secrets {
  local SECRET_VARS_PATH="./group_vars/apache-cassandra/secret_vars"
  local VAULT_PASS=$(openssl rand -base64 32)
  local TEMP_ROOT_PASS=$(openssl rand -base64 32)
  echo "${VAULT_PASS}" > ./.vault-pass
  cat << EOF > ${SECRET_VARS_PATH}
`ansible-vault encrypt_string "${TEMP_ROOT_PASS}" --name 'root_pass'`
`ansible-vault encrypt_string "${TOKEN_PASSWORD}" --name 'api_token'`
EOF
}

function ssh_key {
    ssh-keygen -o -a 100 -t ed25519 -C "ansible" -f "${HOME}/.ssh/id_ansible_ed25519" -q -N "" <<<y >/dev/null
    export ANSIBLE_SSH_PUB_KEY=$(cat ${HOME}/.ssh/id_ansible_ed25519.pub)
    export ANSIBLE_SSH_PRIV_KEY=$(cat ${HOME}/.ssh/id_ansible_ed25519)
    export SSH_KEY_PATH="${HOME}/.ssh/id_ansible_ed25519"
    chmod 700 ${HOME}/.ssh
    chmod 600 ${SSH_KEY_PATH}
    eval $(ssh-agent)
    ssh-add ${SSH_KEY_PATH}
    echo -e "\nprivate_key_file = ${SSH_KEY_PATH}" >> ansible.cfg
}

function lint {
  yamllint .
  ansible-lint
  flake8
}

function verify {
    ansible-playbook -i hosts verify.yml
    destroy
}

# production
function ansible:build {
  secrets
  ssh_key
  # write vars file
  sed 's/  //g' <<EOF > ${VARS_PATH}
  # linode vars
  ssh_keys: ${ANSIBLE_SSH_PUB_KEY}
  instance_prefix: ${INSTANCE_PREFIX}
  type: ${LINODE_PARAMS[0]}
  region: ${LINODE_PARAMS[1]}
  image: ${LINODE_PARAMS[2]}
  linode_tags: ${TAGS}
  uuid: ${UUID}
  # sudo user
  sudo_username: ${SUDO_USERNAME}
  username: ${SUDO_USERNAME}
  cluster_count: ${CLUSTER_COUNT}
  # db user
  db_user: ${DB_USER}
  # ssl/tls
  country_name: ${COUNTRY_NAME}
  state_or_province_name: ${STATE_OR_PROVINCE_NAME}
  locality_name: ${LOCALITY_NAME}
  organization_name: ${ORGANIZATION_NAME}
  email_address: ${EMAIL_ADDRESS}
  ca_common_name: ${CA_COMMON_NAME}
  common_name: ${COMMON_NAME}
  cluster_name: ${CLUSTER_NAME}
  client_count: ${CLIENT_COUNT}
  # paths
  cassandra_config: '/etc/cassandra/cassandra.yaml'
  cassandra_ssl_path: '/etc/cassandra/ssl/'
  cassandra_cacert: '/etc/cassandra/ssl/ca.crt'
  cassandra_cakey: '/etc/cassandra/ssl/ca.key'
  cassandra_cacsr: '/etc/cassandra/ssl/ca-csr'
  cassandra_truststore: '/etc/cassandra/ssl/cassandra-truststore.jks'
EOF
}

function ansible:deploy {
  ansible-playbook -v provision.yml
  ansible-playbook -v -i hosts site.yml --extra-vars "root_password=${ROOT_PASS} add_keys_prompt=${ADD_SSH_KEYS}"
}

# main
case $1 in
    ansible:build) "$@"; exit;;
    ansible:deploy) "$@"; exit;;
esac