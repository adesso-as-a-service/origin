#!/bin/bash
#
# This scripts starts the OpenShift server with a default configuration.
# The OpenShift Docker registry and router are installed.
# It will run all tests that are imported into test/extended.

set -o errexit
set -o nounset
set -o pipefail

OS_ROOT=$(dirname "${BASH_SOURCE}")/../..
source "${OS_ROOT}/hack/util.sh"
source "${OS_ROOT}/hack/common.sh"
os::log::install_errexit
cd "${OS_ROOT}"

os::build::setup_env

export TMPDIR="${TMPDIR:-"/tmp"}"
export BASETMPDIR="${TMPDIR}/openshift-extended-tests/authentication"
export EXTENDED_TEST_PATH="${OS_ROOT}/test/extended"
export KUBE_REPO_ROOT="${OS_ROOT}/../../../k8s.io/kubernetes"

function join { local IFS="$1"; shift; echo "$*"; }


function cleanup()
{
	out=$?
	cleanup_openshift
	echo "[INFO] Exiting"
	exit $out
}

trap "exit" INT TERM
trap "cleanup" EXIT

echo "[INFO] Starting server"

ensure_iptables_or_die
setup_env_vars
reset_tmp_dir
configure_os_server
start_os_server

export KUBECONFIG="${ADMIN_KUBECONFIG}"

install_registry
wait_for_registry

oc login ${MASTER_ADDR} -u ldap -p password --certificate-authority=${MASTER_CONFIG_DIR}/ca.crt
oc new-project openldap

# create all the resources we need
oc create -f test/extended/fixtures/ldap

is_event_template=(               \
"{{with \$tags := .status.tags}}" \
    "{{range \$tag := \$tags}}"   \
        "{{\$tag.tag}} "          \
    "{{end}}"                     \
"{{end}}"                         \
)
is_event_template=$(IFS=""; echo "${is_event_template[*]}") # re-formats template for use

# wait until the last event that occurred on the imagestream was the successful pull of the latest image
wait_for_command 'oc get imagestream openldap --template="${is_event_template}" | grep latest' $((60*TIME_SEC))

# kick off a build and wait for it to finish
oc start-build openldap --follow

server_ready_template=(                                  \
"{{with \$items := .items}}"                             \
    "{{with \$item := index \$items 0}}"                 \
        "{{range \$map := \$item.status.conditions}}"    \
            "{{with \$state := index \$map \"type\"}}"   \
                "{{\$state}}"                            \
            "{{end}}"                                    \
            "{{with \$valid := index \$map \"status\"}}" \
                "{{\$valid}} "                           \
            "{{end}}"                                    \
        "{{end}}"                                        \
    "{{end}}"                                            \
"{{end}}"                                                \
)
server_ready_template=$(IFS=$""; echo "${server_ready_template[*]}") # re-formats template for use

# wait for LDAP server to be ready
wait_for_command 'oc get pods -l deploymentconfig=openldap-server --template="${server_ready_template}" | grep "ReadyTrue "' $((60*TIME_SEC))

# TODO(skuznets): readiness check is premature
sleep 10

oc login -u system:admin -n openldap


LDAP_SERVICE_IP=$(oc get --output-version=v1beta3 --template="{{ .spec.portalIP }}" service openldap-server)

function compare_and_cleanup() {
	validation_file=$1
	actual_file=actual-${validation_file}.yaml
	rm -f ${WORKINGDIR}/${actual_file}
	oc get groups --no-headers | awk '{print $1}' | sort | xargs -I{} oc export group {} -o yaml >> ${WORKINGDIR}/${actual_file}
	os::util::sed '/sync-time/d' ${WORKINGDIR}/${actual_file}
	diff ${validation_file} ${WORKINGDIR}/${actual_file}
	oc delete groups --all
	echo -e "\tSUCCESS"
}

oc login -u system:admin -n default

echo "[INFO] Running extended tests"

schema=('rfc2307' 'ad' 'augmented-ad')

for (( i=0; i<${#schema[@]}; i++ )); do
	current_schema=${schema[$i]}
	echo "[INFO] Testing schema: ${current_schema}"

	WORKINGDIR=${BASETMPDIR}/${current_schema}
	mkdir ${WORKINGDIR}

	# create a temp copy of the test files
	cp test/extended/authentication/ldap/${current_schema}/* ${WORKINGDIR}
	pushd ${WORKINGDIR} > /dev/null

	# load OpenShift and LDAP group UIDs, needed for literal whitelists
	# use awk instead of sed for compatibility (see os::util::sed)
	group1_ldapuid=$(awk 'NR == 1 {print $0}' ldapgroupuids.txt)
	group2_ldapuid=$(awk 'NR == 2 {print $0}' ldapgroupuids.txt)
	group3_ldapuid=$(awk 'NR == 3 {print $0}' ldapgroupuids.txt)

	group1_osuid=$(awk 'NR == 1 {print $0}' osgroupuids.txt)
	group2_osuid=$(awk 'NR == 2 {print $0}' osgroupuids.txt)
	group3_osuid=$(awk 'NR == 3 {print $0}' osgroupuids.txt)

	# update sync-configs and validation files with the LDAP server's IP
	config_files=sync-config*.yaml
	validation_files=valid*.yaml
	for config in ${config_files} ${validation_files}
	do
		os::util::sed "s/LDAP_SERVICE_IP/${LDAP_SERVICE_IP}/g" ${config}
	done

	echo -e "\tTEST: Sync all LDAP groups from LDAP server"
	openshift ex sync-groups --sync-config=sync-config.yaml --confirm
	compare_and_cleanup valid_all_ldap_sync.yaml


	# WHITELISTS
	echo -e "\tTEST: Sync subset of LDAP groups from LDAP server using whitelist file"
	openshift ex sync-groups --whitelist=whitelist_ldap.txt --sync-config=sync-config.yaml --confirm
	compare_and_cleanup valid_whitelist_sync.yaml

	echo -e "\tTEST: Sync subset of LDAP groups from LDAP server using literal whitelist"
	openshift ex sync-groups ${group1_ldapuid} --sync-config=sync-config.yaml --confirm
	compare_and_cleanup valid_whitelist_sync.yaml

	echo -e "\tTEST: Sync subset of LDAP groups from LDAP server using union of literal whitelist and whitelist file"
	openshift ex sync-groups ${group2_ldapuid} --whitelist=whitelist_ldap.txt --sync-config=sync-config.yaml --confirm
	compare_and_cleanup valid_whitelist_union_sync.yaml

	echo -e "\tTEST: Sync subset of OpenShift groups from LDAP server using whitelist file"
	openshift ex sync-groups ${group1_ldapuid} --sync-config=sync-config.yaml --confirm
	oc patch group ${group1_osuid} -p 'users: []'
	openshift ex sync-groups --type=openshift --whitelist=whitelist_openshift.txt --sync-config=sync-config.yaml --confirm
	compare_and_cleanup valid_whitelist_sync.yaml

	echo -e "\tTEST: Sync subset of OpenShift groups from LDAP server using literal whitelist"
	# sync group from LDAP
	openshift ex sync-groups ${group1_ldapuid} --sync-config=sync-config.yaml --confirm
	oc patch group ${group1_osuid} -p 'users: []'
	openshift ex sync-groups --type=openshift ${group1_osuid} --sync-config=sync-config.yaml --confirm
	compare_and_cleanup valid_whitelist_sync.yaml

	echo -e "\tTEST: Sync subset of OpenShift groups from LDAP server using union of literal whitelist and whitelist file"
	# sync groups from LDAP
	openshift ex sync-groups ${group1_ldapuid} ${group2_ldapuid} --sync-config=sync-config.yaml --confirm
	oc patch group ${group1_osuid} -p 'users: []'
	oc patch group ${group2_osuid} -p 'users: []'
	openshift ex sync-groups --type=openshift group/${group2_osuid} --whitelist=whitelist_openshift.txt --sync-config=sync-config.yaml --confirm
	compare_and_cleanup valid_whitelist_union_sync.yaml


	# BLACKLISTS
	echo -e "\tTEST: Sync subset of LDAP groups from LDAP server using whitelist and blacklist file"
	# openshift ex sync-groups --whitelist=ldapgroupuids.txt --blacklist=blacklist_ldap.txt --blacklist-group="${group1_ldapuid}" --sync-config=sync-config.yaml --confirm
	openshift ex sync-groups --whitelist=ldapgroupuids.txt --blacklist=blacklist_ldap.txt --sync-config=sync-config.yaml --confirm
	compare_and_cleanup valid_all_blacklist_sync.yaml

	echo -e "\tTEST: Sync subset of LDAP groups from LDAP server using blacklist"
	# openshift ex sync-groups --blacklist=blacklist_ldap.txt --blacklist-group=${group1_ldapuid} --sync-config=sync-config.yaml --confirm
	openshift ex sync-groups --blacklist=blacklist_ldap.txt --sync-config=sync-config.yaml --confirm
	compare_and_cleanup valid_all_blacklist_sync.yaml

	echo -e "\tTEST: Sync subset of OpenShift groups from LDAP server using whitelist and blacklist file"
	openshift ex sync-groups --sync-config=sync-config.yaml --confirm
	oc get group -o name --no-headers | xargs -n 1 oc patch -p 'users: []'
	# openshift ex sync-groups --type=openshift --whitelist=osgroupuids.txt --blacklist=blacklist_openshift.txt --blacklist-group=${group1_osuid} --sync-config=sync-config.yaml --confirm
	openshift ex sync-groups --type=openshift --whitelist=osgroupuids.txt --blacklist=blacklist_openshift.txt --sync-config=sync-config.yaml --confirm
	compare_and_cleanup valid_all_openshift_blacklist_sync.yaml


	# MAPPINGS
	echo -e "\tTEST: Sync all LDAP groups from LDAP server using a user-defined mapping"
	openshift ex sync-groups --sync-config=sync-config-user-defined.yaml --confirm
	compare_and_cleanup valid_all_ldap_sync_user_defined.yaml

	echo -e "\tTEST: Sync all LDAP groups from LDAP server using a partially user-defined mapping"
	openshift ex sync-groups --sync-config=sync-config-partially-user-defined.yaml --confirm
	compare_and_cleanup valid_all_ldap_sync_partially_user_defined.yaml

	echo -e "\tTEST: Sync based on OpenShift groups respecting OpenShift mappings"
	openshift ex sync-groups --sync-config=sync-config-user-defined.yaml --confirm
	oc get group -o name --no-headers | xargs -n 1 oc patch -p 'users: []'
	openshift ex sync-groups --type=openshift --sync-config=sync-config.yaml --confirm
	compare_and_cleanup valid_all_ldap_sync_user_defined.yaml



	echo -e "\tTEST: Sync all LDAP groups from LDAP server using DN as attribute whenever possible"
    openshift ex sync-groups --sync-config=sync-config-dn-everywhere.yaml --confirm
	compare_and_cleanup valid_all_ldap_sync_dn_everywhere.yaml

	# PRUNING
	echo -e "\tTEST: Sync all LDAP groups from LDAP server, change LDAP UID, then prune OpenShift groups"
	openshift ex sync-groups --sync-config=sync-config.yaml --confirm
	oc patch group ${group2_osuid} -p "{\"metadata\":{\"annotations\":{\"openshift.io/ldap.uid\":\"cn=garbage,${group2_ldapuid}\"}}}"
	openshift ex prune-groups --sync-config=sync-config.yaml --confirm
	compare_and_cleanup valid_all_ldap_sync_prune.yaml

    popd > /dev/null
done
