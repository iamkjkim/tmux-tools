#!/bin/bash

function initialize {
	TMUX_BIN=${TMUX_BIN:-tmux}
	TM_CONNECTOR=${TM_CONNECTOR:-/usr/bin/ssh}

	DEFAULT_WINDOW_COLUMNS=${COLUMNS:-$(tput cols)}
	DEFAULT_WINDOW_LINES=${LINES:-$(tput lines)}

	DEFAULT_PANES_HORIZONTAL=2
	DEFAULT_PANES_VERTICAL=2
}

function _help() {
	echo -e 1>&2 "Usage)\t$0 [-s <session name>] [-x columns] [-y rows] [-l columns] [-r rows] <hostnames or files>"
	echo -e 1>&2 "\t-s <session name>: session name"
	echo -e 1>&2 "\t-x <number>: number of horizontal panes per window (default: $DEFAULT_PANES_HORIZONTAL)"
	echo -e 1>&2 "\t-y <number>: number of vertical panes per window (default: $DEFAULT_PANES_VERTICAL)"
	echo -e 1>&2 "\t-c <number>: width of window (default: $DEFAULT_WINDOW_COLUMNS)"
	echo -e 1>&2 "\t-l <number>: height of window (default: $DEFAULT_WINDOW_LINES)"
}

initialize

while getopts "s:x:y:c:l:h" opt
do
	case $opt in
		s)
			p_session=$OPTARG
			;;
		x)
			p_x=$OPTARG
			;;
		y)
			p_y=$OPTARG
			;;
		c)
			p_c=$OPTARG
			;;
		l)
			p_l=$OPTARG
			;;
		h)
			_help
			exit 0
			;;
	esac
done
shift $[OPTIND-1]

function parse_arguments() {
	[ -z "$p_x" ] && p_x=$DEFAULT_PANES_HORIZONTAL
	[ -z "$p_y" ] && p_y=$DEFAULT_PANES_VERTICAL
	[ -z "$p_c" ] && p_c=$DEFAULT_WINDOW_COLUMNS
	[ -z "$p_l" ] && p_l=$DEFAULT_WINDOW_LINES

	TMUX_VERSION=$($TMUX_BIN -V | awk '{print $2;}')

	if [ "$TMUX_VERSION" \> "1.4" ]
	then
		p_l=$[ p_l + 1 ]
	fi

	if [ -z "$p_session" ]
	then
		_help
		exit 1
	fi
}

declare -a TMUX_COMMANDS
NUM_PANES=0

function generate_tmux_commands() {
	local _n_x=$1
	local _n_y=$2
	local _session=$3
	shift 3

	local -a _rx
	local _x=${_n_x}
	while [ $_x -ge 2 ]
	do
		_rx[${#_rx[@]}]=$[ 100 - 100 / _x ]
		let _x--
	done

	declare -a _ry
	local _y=${_n_y}
	while [ $_y -ge 2 ]
	do
		_ry[${#_ry[@]}]=$[ 100 - 100 / _y ]
		let _y--
	done

	local _r
	for _r in ${_rx[@]}
	do
		echo "rx=$_r"
	done
	for _r in ${_ry[@]}
	do
		echo "ry=$_r"
	done

	if [ "$TMUX_VERSION" \> "2.2" ]
	then
		local _ph=y
	fi

	TMUX_COMMANDS[${#TMUX_COMMANDS[@]}]=$_session	# dummy

	local _x=0
	local _p=0
	local _t

	while [ $_x -lt $_n_x ]
	do
		if [ $_x -eq 0 ]
		then
			local _y=1
			while [ $_y -lt $_n_y ]
			do
				echo "_x=$_x, _y=$_y"
				TMUX_COMMANDS[${#TMUX_COMMANDS[@]}]="$TMUX_BIN split-window -p ${_ry[$[_y-1]]} -v -t $_session"
				let _y++
			done
			if [ $_n_x -lt $_n_y ]
			then
				_t=$[_n_y-_n_x-1]
			fi
		else
			local _y=0
			if [ "$_ph" = "y" ]
			then
				_p=$[ _x - 1 ]
			fi
			while [ $_y -lt $_n_y ]
			do
				echo "_x=$_x, _y=$_y"
				if [ $_n_x -lt $_n_y ]
				then
					TMUX_COMMANDS[${#TMUX_COMMANDS[@]}]="$TMUX_BIN split-window -p ${_ry[$[_t]]} -h -t $_session.$_p"
				else
					TMUX_COMMANDS[${#TMUX_COMMANDS[@]}]="$TMUX_BIN split-window -p ${_rx[$[_x-1]]} -h -t $_session.$_p"
				fi
				let _y++
				if [ "$_ph" = "y" ]
				then
					let _p+=_x+1
				else
					let _p++
				fi
			done
		fi
		let _x++
		if [ $_n_x -lt $_n_y ]
		then
			let _t++
		fi
	done

	local _i=0
	local _c
	for _c in "${TMUX_COMMANDS[@]}"
	do
		echo "$_i: $_c"
		let _i++
	done

	NUM_PANES=$[_n_x*_n_y]
}

CREATED_PANES=0

function create_window() {
	local _session=$1
	local _remote=$2
	shift 2

	local _rv
	local _cmd

	$TMUX_BIN has-session -t $_session
	if [ $? -ne 0 ]
	then
		$TMUX_BIN new-session -d -s $_session -n $_remote -x $p_c -y $p_l "$TM_CONNECTOR $_remote"
		if [ $? -eq 0 ]
		then
			let CREATED_PANES++
		fi
	else
		if [ $[CREATED_PANES % NUM_PANES] -eq 0 ]
		then
			$TMUX_BIN new-window -t $_session -n $_remote "$TM_CONNECTOR $_remote"
			_rv=$?
		else
			_cmd="${TMUX_COMMANDS[$[CREATED_PANES % NUM_PANES]]} \"$TM_CONNECTOR $_remote\""
			eval $_cmd
			_rv=$?
		fi
		if [ $_rv -eq 0 ]
		then
			let CREATED_PANES++
		fi
	fi
}

function tmux_connect() {
	local _remote=$1
	shift
	create_window $p_session $_remote
}

function report() {
	if [ $CREATED_PANES -ne 0 ]
	then
		local _remains=$[NUM_PANES - CREATED_PANES % NUM_PANES]
		echo "Created $CREATED_PANES panes ($_remains/$NUM_PANES)"
	fi
}

function cleanup() {
	echo 1>&2 "*** Trapped SIGINT ***"
	_report
	exit 1
}

parse_arguments
generate_tmux_commands $p_x $p_y $p_session

trap cleanup INT

loop_fn=tmux_connect

function execute() {
	local _remote=$1
	shift
	if echo $_remote | egrep -q '^#'
	then
		if [ "x$lf_quiet" != "xy" ]
		then
			_remote=`echo $_remote | sed -e 's/^#*//'`
			printf "### %-24s ##############################\n" $_remote
		fi
		return 0
	fi
	if [ "x$lf_quiet" != "xy" ]
	then
		printf "=== %-24s ==============================\n" $_remote
	fi
	eval $loop_fn $_remote
}

if [ -z "$loop_fn" ]
then
	echo 1>&2 'Empty function'
	exit 1
fi

# Process positional arguments
for arg in "$@"
do
	if [ -f "$arg" ]
	then
		list=$arg
		exec 3<$list
		while read -u 3 line
		do
			execute $line
		done
		unset line
		unset list
	else
		execute $arg
	fi
done
unset arg

report
