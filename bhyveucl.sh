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
: ${JQ_CMD:=/usr/local/bin/jq --raw-output}
: ${BHYVE_CMD:=/usr/sbin/bhyve}
: ${BHYVE_FLAGS=}
: ${BHYVE_LOAD_CMD:=/usr/sbin/bhyveload}
: ${BHYVE_LOAD_FLAGS=}
: ${BHYVE_GRUB_CMD:=/usr/local/sbin/grub-bhyve}
: ${BHYVE_GRUB_FLAGS=}


kldstat -n vmm > /dev/null 2>&1 
if [ $? -ne 0 ]; then
	echo "Error: vmm.ko is not loaded!"
	exit 1
fi

if [ $# -ne 1 ]; then
	echo "Error: path to config file required"
	exit 2
fi

CONF="$1"
if [ ! -f "$CONF" ]; then
	echo "Error: cannot read config file"
	exit 3
fi

jq "." "$CONF" > /dev/null
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
		type=$($JQ_CMD ".flags[${n}] | to_entries[0] .value | type" "$CONF")
		if [ "$type" = "string" ]; then
			bhyve_load_vars "_key _value" ".flags[${n}] | to_entries[0] | .key, .value"
			flags="${flags}${_key} '"${_value}"' "
		elif [ "$type" = "array" ]; then
			_key=$($JQ_CMD ".flags[${n}] | to_entries[0] | .key" "$CONF")
			local parse
			parse=$($JQ_CMD ".flags[${n}] | to_entries[0] | .value[]" "$CONF")
			oIFS=$IFS
			IFS=$'\n'
			for v in $parse; do
				flags="${flags}${_key} '"${v}"' "
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
	local parse
	parse=$($JQ_CMD "$2" "$CONF")

	oIFS=$IFS
	IFS=$'\n'

	bhyve_load_newline "$1" $parse

	IFS=$oIFS
}

bhyve_load_newline()
{
	local vlist
	vlist="$1"
	shift 1

	IFS=$oIFS

	for v in $vlist; do
		if [ "$DEBUG" -gt 0 ]; then
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
			dlist="${dlist}.${v}, "
		done
		vlist=${vlist%% }
		dlist=${dlist%%, }
		bhyve_load_vars "$vlist" ".${tree}[${n}] | ${dlist}"
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
			dlist="${dlist}.${v}, "
		done
		vlist=${vlist%% }
		dlist=${dlist%%, }
		bhyve_load_vars "$vlist" ".${tree}[${n}] | ${dlist}"
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
			dlist="${dlist}.${v}, "
		done
		vlist=${vlist%% }
		dlist=${dlist%%, }
		bhyve_load_vars "$vlist" ".${tree}[${n}] | ${dlist}"
		# Autogenerate slot number
		_slot="$__SLOT"
		__SLOT=$(( $__SLOT + 1))
		eval _type="\$bhyve_${tree}_${n}_type"
		# Generate configuration
		eval _path="\$bhyve_${tree}_${n}_path"
		_flags=$($JQ_CMD ".${tree}[${n}] | .flags" "$CONF")
		if [ "$_flags" != "null" ]; then
			_flags=$($JQ_CMD ".${tree}[${n}] | .flags[]" "$CONF")
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

varlist="VMNAME VMUUID VMCPUS VMMEMORY VMCONSOLE \
	VMLOADER VMLOADER_ARGS VMLOADER_INPUT"
allvarlist="${varlist} VMFEATURES VMFLAGS VMDEV VMNIC VMDISK"

VMFEATURES=""
VMFLAGS=""
VMDEV=""
VMNIC=""
VMDISK=""

# Where to start auto-assigning slot numbers
__SLOT=5

bhyve_load_vars "$varlist" ".name, .uuid, .cpus, .memory, .console, \
	.loader, .loader_args, .loader_input"

# Add flags for features
features=$($JQ_CMD ".features[]" "$CONF")
bhyve_parse_features $features

# Add other flags
num_flags=$($JQ_CMD ".flags | length" "$CONF")
bhyve_parse_flags

# Add flags for devices
num_dev=$($JQ_CMD ".devices | length" "$CONF")
bhyve_parse_dev "devices" "$num_dev" "slot type conf"

# Add flags for network cards
num_nic=$($JQ_CMD ".networks | length" "$CONF")
bhyve_parse_nic "networks" "$num_nic" "type name mac"

# Add flags for disks
num_disk=$($JQ_CMD ".disks | length" "$CONF")
bhyve_parse_disk "disks" "$num_disk" "type path"

if [ "$VMUUID" = "null" ]; then
	VMUUID=$(/bin/uuidgen)
fi

# Remove trailing spaces
VMFEATURES=${VMFEATURES%% }
VMFLAGS=${VMFLAGS%% }
VMDEV=${VMDEV%% }
VMNIC=${VMNIC%% }
VMDISK=${VMDISK%% }

if [ "$DEBUG" -gt 0 ]; then
	for d in $allvarlist; do
		eval val=\$$d
		echo "$d='$val'"
	done
fi


echo

if [ "$VMLOADER" = "grub-bhyve" ]; then
	echo "bhyve grub load command:"
	echo printf "${VMLOADER_INPUT}" \| \
		${BHYVE_GRUB_CMD} ${BHYVE_GRUB_FLAGS} \
		-M ${VMMEMORY}M \
		${VMLOADER_ARGS} \
		${VMNAME}
else
	echo "bhyve load command:"
	echo ${BHYVE_LOAD_CMD} ${BHYVE_LOAD_FLAGS} \
		-c com1,${VMCONSOLE} \
		-m ${VMMEMORY}M \
		-d ${bhyve_disks_0_path} \
		${VMNAME}
fi

echo
echo "bhyve run command:"
echo ${BHYVE_CMD} ${BHYVE_FLAGS} \
	-c ${VMCPUS} \
	-l com1,${VMCONSOLE} \
	-m ${VMMEMORY}M \
	-U ${VMUUID} \
	${VMFEATURES} \
	${VMFLAGS} \
	${VMDEV} \
	${VMNIC} \
	${VMDISK} \
	${VMNAME}

echo
