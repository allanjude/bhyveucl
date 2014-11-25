#!/bin/sh
#
# Copyright (c) 2014 ScaleEngine Inc.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
# $FreeBSD$
#

: ${DEBUG:=0}
: ${BOOTDISK:=0}
: ${UCL_CMD:=/usr/local/bin/uclcmd --noquote}
: ${BHYVE_CMD:=/usr/sbin/bhyve}
: ${BHYVE_FLAGS=}
: ${BHYVE_LOAD_CMD:=/usr/sbin/bhyveload}
: ${BHYVE_LOAD_FLAGS=}
: ${BHYVE_GRUB_CMD:=/usr/local/sbin/grub-bhyve}
: ${BHYVE_GRUB_FLAGS=}
: ${RUN_PREFIX:=}
: ${RUN_SUFFIX:=}

module_loaded() {
	local module
	module="$1"
	shift
	kldstat -q -m $module > /dev/null 2>&1
	if [ $? -ne 0 ]; then
		echo "Error: $module is not loaded!"
		exit 1
	fi
}

module_loaded "vmm"
module_loaded "if_tap"
module_loaded "if_bridge"
module_loaded "if_vlan"

while getopts b:d: c ; do
        case $c in
        b)
                BOOTDISK="${OPTARG}"
                ;;
        d)
                DEBUG="${OPTARG}"
                ;;
        esac
done
shift $((${OPTIND} - 1))

if [ $# -ne 1 ]; then
	echo "Error: path to config file required"
	exit 2
fi

CONF="$1"
if [ ! -f "$CONF" ]; then
	echo "Error: cannot read config file"
	exit 3
fi

$UCL_CMD --file "$CONF" "" > /dev/null
if [ $? != 0 ]; then
	echo "Error: error parsing config file"
	exit 4
fi

bhyve_parse_features()
{
	for var in "$@"; do
		case $var in
			acpi)
				VMFEATURES="${VMFEATURES}-A "
				;;
			coredump)
				VMFEATURES="${VMFEATURES}-C "
				;;
			unhandledio)
				VMFEATURES="${VMFEATURES}-e "
				;;
			vmexithlt)
				VMFEATURES="${VMFEATURES}-H "
				;;
			vmexitpause)
				VMFEATURES="${VMFEATURES}-P "
				;;
			ignoremsr)
				VMFEATURES="${VMFEATURES}-w "
				;;
			singlevectormsi)
				VMFEATURES="${VMFEATURES}-W "
				;;
			x2apic)
				VMFEATURES="${VMFEATURES}-x "
				;;
			nomptable)
				VMFEATURES="${VMFEATURES}-Y "
				;;
			*)
				echo "Error: Unknown feature flag: $var"
				exit 5
				;;
		esac
	done

}

bhyve_parse_flags()
{
	local flags type
	[ $num_flags -le 0 ] && return
	for n in $(jot $num_flags 0); do
		type=$($UCL_CMD --file "$CONF" ".guest.flags.${n}|each|type")
		if [ "$type" = "string" ]; then
			bhyve_load_vars "_key _value" ".guest.flags.${n}|keys" ".flags.${n}|values"
			flags="${flags}-${_key} "${_value}" "
		elif [ "$type" = "array" ]; then
			_key=$($UCL_CMD --file "$CONF" ".guest.flags.${n}|keys")
			local parse
			parse=$($UCL_CMD --file "$CONF" ".guest.flags.${n}.${_key}|values")
			oIFS=$IFS
			IFS=$'\n'
			for v in $parse; do
				flags="${flags}-${_key} "${v}" "
			done
			IFS=$oIFS
		else
			echo "Error: Unknown object type in flags"
			exit 6
		fi
	done
	flags=${flags%% }
	VMFLAGS="$flags"
}

bhyve_load_vars()
{
	local parse result
        result=$1;
        shift
	parse=$($UCL_CMD --file "$CONF" $@)

	oIFS=$IFS
	IFS=$'\n'

	bhyve_load_newline "$result" $parse

	IFS=$oIFS
}

bhyve_load_newline()
{
	local vlist
	vlist="$1"
	shift 1

	IFS=$oIFS

	for v in $vlist; do
		if [ $DEBUG -gt 1 ]; then
			echo "setting $v to '$1'"
		fi
		export $v="$1";
		shift
	done
}

bhyve_parse_dev()
{
	local numdev srcvlist tree
	tree="$1"
	numdev="$2"
	srcvlist="$3"
	vlist=""
	shift 3
	[ $numdev -le 0 ] && return
	for n in $(jot $numdev 0); do
		vlist=""
		dlist=""
		for v in $srcvlist; do
			vlist="${vlist}bhyve_${tree}_${n}_${v} "
			dlist="${dlist}.guest.${tree}.${n}.${v} "
		done
		vlist=${vlist%% }
		dlist=${dlist%% }
		bhyve_load_vars "$vlist" ${dlist}
		eval _slot="\$bhyve_${tree}_${n}_slot"
		eval _type="\$bhyve_${tree}_${n}_type"
		eval _conf="\$bhyve_${tree}_${n}_conf"
		# Autogenerate slot number if not defined
		if [ "$_slot" = "null" ]; then
			_slot="$__SLOT"
			__SLOT=$(( $__SLOT + 1))
		fi
		if [ "$_conf" = "null" ]; then
			VMDEV="${VMDEV}-s ${_slot},${_type} "
		else
			VMDEV="${VMDEV}-s ${_slot},${_type},${_conf} "
		fi
	done
}

bhyve_parse_nic()
{
	local numdev srcvlist tree
	tree="$1"
	numdev="$2"
	srcvlist="$3"
	vlist=""
	shift 3
	[ $numdev -le 0 ] && return
	for n in $(jot $numdev 0); do
		vlist=""
		dlist=""
		for v in $srcvlist; do
			vlist="${vlist}bhyve_${tree}_${n}_${v} "
			dlist="${dlist}.guest.${tree}.${n}.${v} "
		done
		vlist=${vlist%% }
		dlist=${dlist%% }
		bhyve_load_vars "$vlist" ${dlist}
		# Autogenerate slot number
		_slot="$__SLOT"
		__SLOT=$(( $__SLOT + 1))
		eval _type="\$bhyve_${tree}_${n}_type"
		# Generate configuration
		eval _name="\$bhyve_${tree}_${n}_name"
		eval _mac="\$bhyve_${tree}_${n}_mac"
		if [ "$_mac" = "null" ]; then
			_conf="${_name}"
		else
			_conf="${_name},mac=${_mac}"
		fi
		if [ "$_conf" = "null" ]; then
			VMNIC="${VMNIC}-s ${_slot},${_type} "
		else
			VMNIC="${VMNIC}-s ${_slot},${_type},${_conf} "
		fi
	done
}

bhyve_parse_disk()
{
	local numdev srcvlist tree
	tree="$1"
	numdev="$2"
	srcvlist="$3"
	vlist=""
	shift 3
	[ $numdev -le 0 ] && return
	for n in $(jot $numdev 0); do
		vlist=""
		dlist=""
		for v in $srcvlist; do
			vlist="${vlist}bhyve_${tree}_${n}_${v} "
			dlist="${dlist}.guest.${tree}.${n}.${v} "
		done
		vlist=${vlist%% }
		dlist=${dlist%% }
		bhyve_load_vars "$vlist" ${dlist}
		# Autogenerate slot number
		_slot="$__SLOT"
		__SLOT=$(( $__SLOT + 1))
		eval _type="\$bhyve_${tree}_${n}_type"
		# Generate configuration
		eval _path="\$bhyve_${tree}_${n}_path"
		_flags=$($UCL_CMD --file  "$CONF" ".${tree}.${n}.flags")
		if [ "$_flags" != "null" ]; then
			_flags=$($UCL_CMD --file "$CONF" ".guest.${tree}.${n}.flags|values")
			_conf="${_path}"
			for f in "$_flags"; do
				_conf="${_conf},$f"
			done
		else
			_conf="${_path}"
		fi
		if [ "$_conf" = "null" ]; then
			VMDISK="${VMDISK}-s ${_slot},${_type} "
		else
			VMDISK="${VMDISK}-s ${_slot},${_type},${_conf} "
		fi
	done
}

host_parse_bridge()
{
	local numdev srcvlist tree
	tree="$1"
	numdev="$2"
	srcvlist="$3"
	vlist=""
	shift 3
	[ $numdev -le 0 ] && return
	for n in $(jot $numdev 0); do
		vlist=""
		dlist=""
		for v in $srcvlist; do
			vlist="${vlist}host_${tree}_${n}_${v} "
			dlist="${dlist}.host.interfaces.${tree}.${n}.${v} "
		done
		type=$($UCL_CMD --file "$CONF" ".host.interfaces.${tree}.${n}.interfaces|type")
		if [ "$type" = "string" ]; then
			bhyve_load_vars "_key _value" "host.interfaces.${tree}.${n}.interfaces|keys" ".host.interfaces.bridges.${n}.interfaces|values"
			_interfaces="${_interfaces}${_key} "${_value}" "
		elif [ "$type" = "array" ]; then
			local parse
			parse=$($UCL_CMD --file "$CONF" ".host.interfaces.bridges.${n}.interfaces|values")
			oIFS=$IFS
			IFS=$'\n'
			for v in $parse; do
				_interfaces="${_interfaces}addm "${v}" "
			done
			IFS=$oIFS
		fi

		vlist=${vlist%% }
		dlist=${dlist%% }
		bhyve_load_vars "$vlist" ${dlist}
		eval _state="\$host_${tree}_${n}_state"
		# Generate configuration
		eval _name="\$host_${tree}_${n}_name"
		IFCFG_BRIDGE="${IFCFG_BRIDGE}ifconfig ${_name} create ; "
		if [ "$_state" = "null" ]; then
			IFCFG_BRIDGE="${IFCFG_BRIDGE}ifconfig ${_name} ${_interfaces} up ; "
		else
			IFCFG_BRIDGE="${IFCFG_BRIDGE}ifconfig ${_name} ${_interfaces}${_state} ; "
		fi
	done
}

host_parse_vlan()
{
	local numdev srcvlist tree
	tree="$1"
	numdev="$2"
	srcvlist="$3"
	vlist=""
	shift 3
	[ $numdev -le 0 ] && return
	for n in $(jot $numdev 0); do
		vlist=""
		dlist=""
		for v in $srcvlist; do
			vlist="${vlist}host_${tree}_${n}_${v} "
			dlist="${dlist}.host.interfaces.${tree}.${n}.${v} "
		done
		vlist=${vlist%% }
		dlist=${dlist%% }
		bhyve_load_vars "$vlist" ${dlist}
		# Generate configuration
		eval _name="\$host_${tree}_${n}_name"
		eval _vlanid="\$host_${tree}_${n}_vlanid"
		eval _vlandev="\$host_${tree}_${n}_vlandev"
		IFCFG_VLAN="${IFCFG_VLAN}ifconfig ${_name} create ; "
		if [ "$_vlanid" != "null" -a "${_vlandev}" != "null" ]; then
			IFCFG_VLAN="${IFCFG_VLAN}ifconfig ${_name} vlan ${_vlanid} vlandev ${_vlandev} up ; "
		fi
	done
}

host_parse_tap()
{
	local numdev srcvlist tree
	tree="$1"
	numdev="$2"
	srcvlist="$3"
	vlist=""
	shift 3
	[ $numdev -le 0 ] && return
	for n in $(jot $numdev 0); do
		vlist=""
		dlist=""
		for v in $srcvlist; do
			vlist="${vlist}host_${tree}_${n}_${v} "
			dlist="${dlist}.host.interfaces.${tree}.${n}.${v} "
		done
		vlist=${vlist%% }
		dlist=${dlist%% }
		bhyve_load_vars "$vlist" ${dlist}
		# Generate configuration
		eval _name="\$host_${tree}_${n}_name"
		eval _state="\$host_${tree}_${n}_state"
		IFCFG_TAP="${IFCFG_TAP}ifconfig ${_name} create ; "
		if [ "$_state" = "null" ]; then
			IFCFG_TAP="${IFCFG_TAP}ifconfig ${_name} up ; "
		else
			IFCFG_TAP="${IFCFG_TAP}ifconfig ${_name} ${_state} ; "
		fi
	done
}

host_parse_destroy_interfaces() {

	for type in bridges vlans taps;
	do
		local parse
		#echo $type
		parse=$(${UCL_CMD} --file "$CONF" ".host.interfaces.${type}|each|.name")
		oIFS=$IFS
		IFS=$'\n'
		for v in $parse; do
			IFCFG_DESTROY="${IFCFG_DESTROY}ifconfig $v destroy ; "
		done
		IFS=$oIFS
	done
}

varlist="VMNAME VMUUID VMCPUS VMMEMORY VMCONSOLE \
	VMBOOTDISK VMLOADER VMLOADER_ARGS VMLOADER_INPUT"
allvarlist="${varlist} VMFEATURES VMFLAGS VMDEV VMNIC VMDISK"

VMFEATURES=""
VMFLAGS=""
VMDEV=""
VMNIC=""
VMDISK=""

# Where to start auto-assigning slot numbers
__SLOT=5

bhyve_load_vars "$varlist" ".guest.name" ".guest.uuid" ".guest.cpus" ".guest.memory" ".guest.console" \
	".guest.disks.${BOOTDISK}.path" ".guest.loader" ".guest.loader_args" ".guest.loader_input"

# Add flags for features
features=$($UCL_CMD --file "$CONF" ".guest.features|values")
bhyve_parse_features $features

# Add other flags
num_flags=$($UCL_CMD --file "$CONF" ".guest.flags|length")
bhyve_parse_flags

# Add flags for devices
num_dev=$($UCL_CMD --file "$CONF" ".guest.devices|length")
bhyve_parse_dev "devices" "$num_dev" "slot type conf"

# Add flags for network cards
num_nic=$($UCL_CMD --file "$CONF" ".guest.networks|length")
bhyve_parse_nic "networks" "$num_nic" "type name mac"

# Add flags for disks
num_disk=$($UCL_CMD --file "$CONF" ".guest.disks|length")
bhyve_parse_disk "disks" "$num_disk" "type path"

if [ "$VMUUID" = "null" ]; then
	VMUUID=$(/bin/uuidgen)
fi
num_bridges=$($UCL_CMD --file "$CONF" ".host.interfaces.bridges|length")
host_parse_bridge "bridges" "$num_bridges" "name interfaces state"

num_vlans=$($UCL_CMD --file "$CONF" ".host.interfaces.vlans|length")
host_parse_vlan "vlans" "$num_vlans" "name vlanid vlandev"

num_taps=$($UCL_CMD --file "$CONF" ".host.interfaces.taps|length")
host_parse_tap "taps" "$num_taps" "name state"

host_parse_destroy_interfaces

# Remove trailing spaces
VMFEATURES=${VMFEATURES%% }
VMFLAGS=${VMFLAGS%% }
MDEV=${VMDEV%% }
MNIC=${VMNIC%% }
MDISK=${VMDISK%% }

if [ $DEBUG -gt 1 ]; then
	for d in $allvarlist; do
		eval val=\$$d
		echo "$d='$val'"
	done
fi

if [ "$VMCONSOLE" != "stdio" ]; then
    # If using a serial console, send bhyve to the background
    RUN_PREFIX="nohup ${RUN_PREFIX}"
    RUN_SUFFIX="2>&1 > ${VMNAME}.out &"
fi

if [ $DEBUG -gt 0 ]; then
    RUN_PREFIX="echo ${RUN_PREFIX}"
    RUN_SUFFIX="2\>\&1 \> ${VMNAME}.out \&"
fi

echo
echo  "Creating network interfaces"
echo  "         vlan   devices"
if [ $DEBUG -gt 0 ]; then
	echo "$IFCFG_VLAN"
else
	eval "$IFCFG_VLAN"
fi
echo  "         tap    devices"
if [ $DEBUG -gt 0 ]; then
	echo "$IFCFG_TAP"
else
	eval "$IFCFG_TAP"
fi
echo  "         bridge devices"
if [ $DEBUG -gt 0 ]; then
	echo "$IFCFG_BRIDGE"
else
	eval "$IFCFG_BRIDGE"
fi

echo
if [ "$VMLOADER" = "grub-bhyve" ]; then
	echo "Running grub-bhyve:"
	echo printf "${VMLOADER_INPUT}" \| \
		${RUN_PREFIX} ${BHYVE_GRUB_CMD} ${BHYVE_GRUB_FLAGS} \
		-M ${VMMEMORY}M \
		${VMLOADER_ARGS} \
		${VMNAME}
else
	echo "Running bhyveload:"
	${RUN_PREFIX} ${BHYVE_LOAD_CMD} ${BHYVE_LOAD_FLAGS} \
		-c ${VMCONSOLE} \
		-m ${VMMEMORY}M \
                -d ${VMBOOTDISK} \
		${VMNAME}
fi

echo
echo "Running bhyve:"
eval ${RUN_PREFIX} ${BHYVE_CMD} ${BHYVE_FLAGS} \
	-c ${VMCPUS} \
	-l com1,${VMCONSOLE} \
	-m ${VMMEMORY}M \
	-U ${VMUUID} \
	${VMFEATURES} \
	${VMFLAGS} \
	${VMDEV} \
	${VMNIC} \
	${VMDISK} \
	${VMNAME} \
	${RUN_SUFFIX}


echo
echo "To remove created network devices, use:"
echo $IFCFG_DESTROY
echo
echo
echo "bhyveucl exiting..."
echo
