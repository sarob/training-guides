#!/usr/bin/env bash
set -o errexit -o nounset
TOP_DIR=$(cd $(dirname "$0")/.. && pwd)
source "$TOP_DIR/config/paths"
source "$CONFIG_DIR/credentials"
source "$LIB_DIR/functions.guest"
source "$CONFIG_DIR/admin-openstackrc.sh"
exec_logfile

indicate_current_auto

#-----------------------------------------------------------------------------------------
# Install the Image Service (glance).
# http://docs.openstack.org/icehouse/install-guide/install/apt/content/glance-install.html
#-----------------------------------------------------------------------------------------

echo "Installing glance."
sudo apt-get install -y glance python-glanceclient

function get_database_url {
    local db_user=$(service_to_db_user glance)
    local db_password=$(service_to_db_password glance)
    local database_host=controller-mgmt

    echo "mysql://$db_user:$db_password@$database_host/glance"
}

database_url=$(get_database_url)

echo "Setting database connection: $database_url."
iniset_sudo /etc/glance/glance-api.conf database connection "$database_url"
iniset_sudo /etc/glance/glance-registry.conf database connection "$database_url"

echo "Removing default SQLite database."
sudo rm -f /var/lib/glance/glance.sqlite

echo "Setting up database for glance."
setup_database glance

echo "Configuring glance."

# TODO: Should we configure the rpc_backend (glance-api.conf) here?

echo "Creating the database tables for glance."
sudo glance-manage db_sync

glance_admin_user=$(service_to_user_name glance)
glance_admin_password=$(service_to_user_password glance)

echo "Creating glance user and giving it admin role under service tenant."
keystone user-create \
    --name "$glance_admin_user" \
    --pass "$glance_admin_password" \
    --email "glance@$MAIL_DOMAIN"

keystone user-role-add \
    --user "$glance_admin_user" \
    --tenant "$SERVICE_TENANT_NAME" \
    --role "$ADMIN_ROLE_NAME"

echo "Configuring glance to use keystone for authentication."

echo "Configuring glance-api.conf."
conf=/etc/glance/glance-api.conf
iniset_sudo $conf keystone_authtoken auth_uri "http://controller-mgmt:5000"
iniset_sudo $conf keystone_authtoken auth_host controller-mgmt
iniset_sudo $conf keystone_authtoken auth_port 35357
iniset_sudo $conf keystone_authtoken auth_protocol http
iniset_sudo $conf keystone_authtoken admin_tenant_name "$SERVICE_TENANT_NAME"
iniset_sudo $conf keystone_authtoken admin_user "$glance_admin_user"
iniset_sudo $conf keystone_authtoken admin_password "$glance_admin_password"
iniset_sudo $conf paste_deploy flavor "keystone"

echo "Configuring glance-registry.conf."
conf=/etc/glance/glance-registry.conf
iniset_sudo $conf keystone_authtoken auth_uri "http://controller-mgmt:5000"
iniset_sudo $conf keystone_authtoken auth_host controller-mgmt
iniset_sudo $conf keystone_authtoken auth_port 35357
iniset_sudo $conf keystone_authtoken auth_protocol http
iniset_sudo $conf keystone_authtoken admin_tenant_name "$SERVICE_TENANT_NAME"
iniset_sudo $conf keystone_authtoken admin_user "$glance_admin_user"
iniset_sudo $conf keystone_authtoken admin_password "$glance_admin_password"
iniset_sudo $conf paste_deploy flavor "keystone"

echo "Registering glance with keystone so that other services can locate it."
keystone service-create \
    --name glance \
    --type image \
    --description "OpenStack Image Service"

glance_service_id=$(keystone service-list | awk '/ image / {print $2}')
keystone endpoint-create \
    --service-id "$glance_service_id" \
    --publicurl "http://controller-api:9292" \
    --adminurl "http://controller-mgmt:9292" \
    --internalurl "http://controller-mgmt:9292"

echo "Restarting glance service."
sudo service glance-registry restart
sudo service glance-api restart

#----------------------------------------------------------------------------------------
# Verify the Image Service installation
# http://docs.openstack.org/icehouse/install-guide/install/apt/content/glance-verify.html
#----------------------------------------------------------------------------------------

echo "Waiting for glance to start."
until glance image-list >/dev/null 2>&1; do
    sleep 1
done

echo "Adding CirrOS image to glance."
glance image-create \
    --name Cirros_x86_64 \
    --is-public true \
    --container-format bare \
    --disk-format qcow2 < "$HOME/img/$(basename $CIRROS_URL)"

echo "Verifying that the image was successfully added to the service."

echo "glance image-list"
glance image-list
