#!/bin/bash

PARENT_DIR=$(dirname $BASH_EXE_PATH)
ROOT_DIR=$(dirname $PARENT_DIR)
PACKAGE_DIR="$ROOT_DIR/_package"
PACKAGE_MONITORING_DIR="$PACKAGE_DIR/monitoring"
NEWLINE=$'\n'
TAB=$'\t'
TWO_SPACES=$'  '
SIX_SPACES=$'      '
EIGTH_SPACES=$'        '

# load environment file
source $PARENT_DIR/templates/.env

EMPTY_DIR=(
	"prometheus"
	"prometheus/rules"
	"docker"
	"host"
	"grafana"
	"blackbox_exporter"
	"alertmanager"
	"azure"
)

GENERAL_MANDATORY_PARAMS=(
	"ENV"
	"PROJECT_NAME"
	"MOUNT_DIR"
	"MONITORING_IP_ADDRESS"
	"MONITORING_RESOURCE_GROUP"
	"MONITORING_RESOURCE_NAME"
	"SLACK_WEB_HOOK_URL"
	"SLACK_CHANNEL_NAME"
)

BOOL_PARAMS=(
	"PROBE_IS_HTTP"
)

HOST_MANDATORY_PARAMS=(
	"IP_ADDRESS"
	"RESOURCE_GROUP"
	"RESOURCE_NAME"
)

WEB_MANDATORY_PARAMS=(
	"URL"
	"RESOURCE_GROUP"
	"RESOURCE_NAME"
)

function validation() {
	if [[ -z $HOST_COUNT && -z $WEB_COUNT ]] || [[ $HOST_COUNT -eq 0 && $WEB_COUNT -eq 0 ]]; then
		echo "'HOST_COUNT' & 'WEB_COUNT' both parameters have value null or 0. Atleast one parameter is required to be configured."
		exit 1
	fi

	HAS_ERROR=false
	for param in "${GENERAL_MANDATORY_PARAMS[@]}"; do
		if [[ -z ${!param} ]]; then
			echo "For parameter '${param}', please assign the value."
			HAS_ERROR=true
		fi
	done

	index=0
	while [ $index -le $((HOST_COUNT - 1)) ]; do
		for param in "${HOST_MANDATORY_PARAMS[@]}"; do
			HOST_PARAM=HOST${index}_${param}
			if [[ -z ${!HOST_PARAM} ]]; then
				echo "For parameter '${HOST_PARAM}', please assign the value."
				HAS_ERROR=true
			else
				__validate_if_host_ip_address_has_correct_format $param $HOST_PARAM
			fi
		done
		((index++))
	done

	index=0
	while [ $index -le $((WEB_COUNT - 1)) ]; do
		for param in "${WEB_MANDATORY_PARAMS[@]}"; do
			WEB_PARAM=WEB${index}_${param}
			if [[ -z ${!WEB_PARAM} ]]; then
				echo "For parameter '${WEB_PARAM}', please assign the value."
				HAS_ERROR=true
			fi
		done
		((index++))
	done

	__validate_if_params_have_correct_bool_value "${BOOL_PARAMS[@]}"

	[[ -z $TENANT_ID ]] && HAS_ERROR=true && echo "TENANT_ID is mandatory for Azure monitoring."
	[[ -z $SUBSCRIPTION_ID ]] && HAS_ERROR=true && echo "SUBSCRIPTION_ID is mandatory for Azure monitoring."
	[[ -z $CLIENT_ID ]] && HAS_ERROR=true && echo "CLIENT_ID is mandatory for Azure monitoring."
	[[ -z $CLIENT_SECRET ]] && HAS_ERROR=true && echo "CLIENT_SECRET is mandatory for Azure monitoring."

	if $HAS_ERROR; then
		echo "please assign the value(s) for above parameters in file '$PARENT_DIR/templates/.env'"
		exit 1
	fi
}

function make_empty_dir() {
	rm -rf $PACKAGE_DIR

	for path in "${EMPTY_DIR[@]}"; do
		mkdir -p $PACKAGE_MONITORING_DIR/$path
	done
}

function prepare_files_from_template() {
	export MSYS_NO_PATHCONV=1

	HERE='{{ if eq .Labels.severity "critical" }}<!here>{{ end }}'

	# copy/export configuration files
	cp -r $PARENT_DIR/templates/grafana $PACKAGE_MONITORING_DIR
	cp $PARENT_DIR/templates/blackbox_exporter/blackbox.yml $PACKAGE_MONITORING_DIR/blackbox_exporter
	MONITORING_IP_ADDRESS=$MONITORING_IP_ADDRESS envsubst <$PARENT_DIR/templates/grafana/grafana.env >$PACKAGE_MONITORING_DIR/grafana/grafana.env

	# copy rules files
	cp -r $PARENT_DIR/templates/prometheus/rules/* $PACKAGE_MONITORING_DIR/prometheus/rules

	# copy alertmanager file
	SLACK_WEB_HOOK_URL=$SLACK_WEB_HOOK_URL SLACK_CHANNEL_NAME=$SLACK_CHANNEL_NAME HERE=$HERE envsubst <$PARENT_DIR/templates/alertmanager/alertmanager.yml >$PACKAGE_MONITORING_DIR/alertmanager/alertmanager.yml

	# copy dashboards
	cp -r $PARENT_DIR/dashboards/* $PACKAGE_MONITORING_DIR/grafana/provisioning/dashboards

	# copy docker/host files
	MOUNT_DIR=$MOUNT_DIR envsubst <$PARENT_DIR/templates/docker/docker-compose.yml >$PACKAGE_MONITORING_DIR/docker/docker-compose.yml
	MOUNT_DIR=$MOUNT_DIR envsubst <$PARENT_DIR/templates/host/resource-monitoring.service >$PACKAGE_MONITORING_DIR/host/resource-monitoring.service

	# copy azure configuration files
	TENANT_ID=$TENANT_ID SUBSCRIPTION_ID=$SUBSCRIPTION_ID CLIENT_ID=$CLIENT_ID CLIENT_SECRET=$CLIENT_SECRET envsubst <$PARENT_DIR/templates/azure/datasource.yml >$PACKAGE_MONITORING_DIR/grafana/provisioning/datasources/azure-${PROJECT_NAME}-datasource.yml
	TENANT_ID=$TENANT_ID SUBSCRIPTION_ID=$SUBSCRIPTION_ID CLIENT_ID=$CLIENT_ID CLIENT_SECRET=$CLIENT_SECRET envsubst <$PARENT_DIR/templates/azure/azure.yml >$PACKAGE_MONITORING_DIR/azure/azure.yml

	# prepare azure.yml dynamically
	start_line="resource_groups:"
	end_line="{LINE_APPEND_PLACE_HOLDER}"

	# lines to be appended dynamically for each resource group
	lines_to_append=$(sed -n "/$start_line/,/$end_line/{//!p;}" $PACKAGE_MONITORING_DIR/azure/azure.yml)

	# remove lines from file between 'start_line' and 'end_line' excluding 'start_line'
	sed -i "/$start_line/,/$end_line/{/$start_line/!d}" $PACKAGE_MONITORING_DIR/azure/azure.yml

	# get distinct resource groups
	azure_resource_groups=()
	for var in $(compgen -v -X '!*_RESOURCE_GROUP'); do
		RG=${!var}
		if [[ "${azure_resource_groups[*]}" != *"${RG}"* ]]; then
			azure_resource_groups+=(${RG})
		fi
	done

	# append line for each distinct rg
	for rg in "${azure_resource_groups[@]}"; do
		echo "$lines_to_append" | sed "s/{RESOURCE_GROUP_PLACE_HOLDER}/$rg/g" >>$PACKAGE_MONITORING_DIR/azure/azure.yml
	done

	__prepare_prometheus_file
}

function zip_deployment_folders() {
	7z a -tzip $PACKAGE_MONITORING_DIR ./$PACKAGE_MONITORING_DIR
}

__target_template() {
	TARGET=${NEWLINE}${SIX_SPACES}
	TARGET+="- targets: ['$1']"
	TARGET+="${NEWLINE}${EIGTH_SPACES}labels:"
	TARGET+="${NEWLINE}${EIGTH_SPACES}${TWO_SPACES}target_env: '${PROJECT_NAME,,}'"
	TARGET+="${NEWLINE}${EIGTH_SPACES}${TWO_SPACES}target_resource_group: '$2'"
	TARGET+="${NEWLINE}${EIGTH_SPACES}${TWO_SPACES}target_resource_name: '$3'"
	echo "$TARGET"
}

__prepare_prometheus_file() {
	TARGET_BLACKBOX_HTTPS_PROBE_LIST="" #[https_2xx -> https requests require ssl validation]
	TARGET_BLACKBOX_HTTP_PROBE_LIST=""  #[http_2xx -> http or https without ssl]

	index=0
	while [ $index -le $((HOST_COUNT - 1)) ]; do
		IP_ADDRESS=HOST${index}_IP_ADDRESS
		RESOURCE_GROUP=HOST${index}_RESOURCE_GROUP
		RESOURCE_NAME=HOST${index}_RESOURCE_NAME

		PORT=5000
		if [[ "${PROBE_IS_HTTP}" == "true" ]]; then
			TARGET_BLACKBOX_HTTP_PROBE=$(__target_template http://${!IP_ADDRESS}:$PORT ${!RESOURCE_GROUP,,} ${!RESOURCE_NAME,,})
		else
			TARGET_BLACKBOX_HTTPS_PROBE=$(__target_template https://${!IP_ADDRESS}:$PORT ${!RESOURCE_GROUP,,} ${!RESOURCE_NAME,,})
		fi

		TARGET_BLACKBOX_HTTP_PROBE_LIST+="${TARGET_BLACKBOX_HTTP_PROBE}${NEWLINE}"
		TARGET_BLACKBOX_HTTPS_PROBE_LIST+="${TARGET_BLACKBOX_HTTPS_PROBE}${NEWLINE}"

		((index++))
	done

	index=0
	while [ $index -le $((WEB_COUNT - 1)) ]; do
		URL=WEB${index}_URL
		RESOURCE_GROUP=WEB${index}_RESOURCE_GROUP
		RESOURCE_NAME=WEB${index}_RESOURCE_NAME

		if [[ ${!URL,,} == http://* ]]; then
			TARGET_BLACKBOX_HTTP_PROBE=$(__target_template ${!URL,,} ${!RESOURCE_GROUP,,} ${!RESOURCE_NAME,,})
			TARGET_BLACKBOX_HTTP_PROBE_LIST+="${TARGET_BLACKBOX_HTTP_PROBE}${NEWLINE}"
		else
			TARGET_BLACKBOX_HTTPS_PROBE=$(__target_template ${!URL,,} ${!RESOURCE_GROUP,,} ${!RESOURCE_NAME,,})
			TARGET_BLACKBOX_HTTPS_PROBE_LIST+="${TARGET_BLACKBOX_HTTPS_PROBE}${NEWLINE}"
		fi
		((index++))
	done

	PROJECT_NAME=${PROJECT_NAME,,} ENV=${ENV,,} MONITORING_RESOURCE_GROUP=${MONITORING_RESOURCE_GROUP,,} MONITORING_RESOURCE_NAME=${MONITORING_RESOURCE_NAME,,} TARGET_NODE_EXPORTER_LIST=$TARGET_NODE_EXPORTER_LIST TARGET_CADVISOR_LIST=$TARGET_CADVISOR_LIST TARGET_PROMTAIL_LIST=$TARGET_PROMTAIL_LIST TARGET_BLACKBOX_HTTPS_PROBE_LIST=$TARGET_BLACKBOX_HTTPS_PROBE_LIST TARGET_BLACKBOX_HTTP_PROBE_LIST=$TARGET_BLACKBOX_HTTP_PROBE_LIST BLACKBOX_PROBE_INTERVAL=$BLACKBOX_PROBE_INTERVAL envsubst <$PARENT_DIR/templates/prometheus/prometheus.yml >$PACKAGE_MONITORING_DIR/prometheus/prometheus.yml

	sed -i 's/ *$// ; N;/^\n$/D;P;D;' $PACKAGE_MONITORING_DIR/prometheus/prometheus.yml
}

# validate if given list of params have correct bool value
__validate_if_params_have_correct_bool_value() {
	local param_list=("$@")

	for param in "${param_list[@]}"; do
		param_value=${!param}
		if [[ -n $param_value ]] && [[ $param_value != true ]] && [[ $param_value != false ]]; then
			echo "For parameter '${param}', please assign one of the value from true|false."
			HAS_ERROR=true
		fi
	done
}

# for a given host param, check if it has valid ip address.
__validate_if_host_ip_address_has_correct_format() {
	local param=$1
	local target_param=$2
	target_value=${!target_param}

	if [[ $param == "IP_ADDRESS" && ! $target_value =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "For parameter '${target_param}', the ip address is not in correct format."
		HAS_ERROR=true
	fi
}
