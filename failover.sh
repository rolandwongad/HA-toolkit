#!/bin/bash
#
# $Id: failover.sh 3.31 2018-05-04 16:16:25 cmayer $
#
# run on the passive node, activate this HA node.
# 
# if run with the -f option, force hard failover
# if run with the -n option, don't remote stop
#    this is usually invoked from the remote side on an orderly shutdown
#
# Copyright 2016 AppDynamics, Inc
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
export PATH=/bin:/usr/bin:/sbin:/usr/sbin

cd $(dirname $0)

LOGFNAME=failover.log

# source function libraries
. lib/log.sh
. lib/runuser.sh
. lib/conf.sh
. lib/ha.sh
. lib/password.sh
. lib/sql.sh

NOTFAILED=3600

function slave_status {
	bounce_slave

	# wait for the slave to settle
	connect_count=0

	while [ $connect_count -lt 3 ] ; do
		eval `get_slave_status`
		case "$slave_io" in
		Connecting) 
			(( connect_count++ ))
			sleep 10
			continue;
			;;
		Yes) break
			;;
		No) break
			;;
		esac
	done
}

#
# parse arguments
#
force=false
break_replication=false
primary_up=false
remote=true
no_assassin=false

while getopts fn: flag; do
	case $flag in
	f)
		force=true
		;;
	n)
		sanity_check=$OPTARG
		if [ "$sanity_check" == "primary_has_been_set_passive_and_stopped" ] ; then
			remote=false
			no_assassin=true
		else
			echo "the -n option is not intended to be run manually"
			exit 1
		fi
		;;
	*)
		echo "usage: $0 <options>"
		echo "    [ -f ] force replication break"
		echo "    [ -n primary_has_been_set_passive_and_stopped ] - not intended for manual use"
		exit
		;;
	esac
done

message "failover log" `date`

check_sanity

#
# we must be the passive node
#
message "Verify passive node"
mode=`get_replication_mode localhost`
if [ "$mode" == "active" ] ; then
	fatal 6 "this script must be run on the passive node"
fi

#
# we must be replicating in some sense
#
message "Verify replication state"
slave=`get_slave_status | wc -l`
if [ "$slave" = 0 ] ; then
	gripe "replication is not running"
	if ! $force ; then
		exit 1
	else
		message "  -- Force Failover even with no slave"
		primary_up=false
	fi
fi
if $force ; then
	break_replication=true
fi

#
# replication must be moderately healthy - it's ok if the other server is down
#
slave_status
if [ "$slave_sql" != "Yes" ] ; then
	message "slave SQL not running - replication error"
	if ! $force ; then
		exit 1
	else
		message "Force Failover - stopped slave"
		primary_up=false
	fi
fi

case "$slave_io" in 
	"Yes")
		primary_up=true
		;;
	"Connecting")
		primary_up=false
		message "Primary DB not running"
		;;
	*)
		message "Unrecognized state for slave IO: $slave_io"
		if ! $force ; then
			exit 1
		else
			message "Force Failover - unknown slave state"
			primary_up=false
		fi
		;;
esac

if ! $primary_up ; then
	break_replication=true
fi


secondary=`sql localhost "show slave status" | get Master_Host`
if [[ -z "$secondary" ]] ; then
	fatal 1 "unable to get Master_Host value from \"show slave status\". Giving up..."
fi
check_ssh_setup $secondary || fatal 1 "2-way passwordless ssh healthcheck failed"

#
# hard failover is not quite as hard as all that.
# in a certain case, we don't break replication if all of:
# (1) slave sql and slave io are running
# (2) uptime is greater than some limit
# then leave replication running
#
if [ "$slave_io" == Yes -a "$slave_sql" == Yes ] ; then
	uptime=0
	secondary=""

	secondary=`sql localhost "show slave status" | get Master_Host`
	if [ -n "$secondary" ] ; then
		uptime=`sql $secondary "show status like 'Uptime'\G" | get Value`
	fi
	if [ "$uptime" -gt $NOTFAILED ] ; then
		break_replication=false	
	fi
fi

#####
#
# at this point, we are committed to failing over
#

#
# kill the local watchdog if it is up
#
kc=0
while [ -f $WATCHDOG_PIDFILE ] ; do
	if [ $(($kc % 10)) -eq 0 ] ; then
		kill `cat $WATCHDOG_PIDFILE` >/dev/null 2>&1
		message "Kill Watchdog"
	fi
	let kc++
	sleep 1
done

#
# call the user pre-hook if one exists - this is a place to turn off old things
#
if [ -x ./failover_pre_hook.sh ] ; then
	./failover_pre_hook.sh
fi

#
# kill the local appserver if it's running
#
message "Kill Local Appserver"
service appdcontroller stop | log 2>&1

#
# if the primary is up, mark it passive, and stop the appserver
# if the primary is not reachable, the assassin will eventually change ha.controller.type
#
if [ "$primary_up" = "true" ] ; then
	if $remote ; then
		message "Mark primary passive + secondary"
		if \
			sql $primary "update global_configuration_local set value='passive' \
				where name = 'appserver.mode';" 10 &&
			sql $primary "update global_configuration_local set value='secondary' \
				where name = 'ha.controller.type';" 10 ; then
			message "Mark local primary"
			no_assassin=true
		else
			message "Primary DB timeout"
			break_replication=true
			no_assassin=false
		fi
		message "Stop primary appserver"
		remservice -tq $primary appdcontroller stop
	fi
fi

#
# persistently break replication
#
if $break_replication ; then
	#
	# we can get here if we could not mark the remote database passive
	#
	if [ "$primary_up" = "true" ] ; then
		message "Stop secondary database"
		remservice -tq $primary appdcontroller-db stop
		dbcnf_unset skip-slave-start $primary
		dbcnf_set skip-slave-start true $primary
	fi

	#
	# now stop the replication slave
	#
	message "Stop local slave"
	sql localhost "stop slave IO_THREAD;"

	message "Disable local slave autostart"

	#
	# disable automatic start of replication slave
	# edit the db.cnf to remove any redundant entries for skip-slave-start
	# this is to ensure that replication does not get turned on by a reboot
	#
	dbcnf_unset skip-slave-start
	dbcnf_set skip-slave-start true
fi

#
# the primary is now down and maybe passive; 
#
message "Mark local active"
sql localhost "update global_configuration_local set value='active' \
	where name = 'appserver.mode';"

if $no_assassin ; then
	sql localhost "update global_configuration_local set value='primary' \
	where name = 'ha.controller.type';"
fi

#
# start the replication sql thread.
#
sql localhost "start slave sql_thread"

waited=false
#
# wait until the all the read relay logs are executed
#
while true ; do
	read_file=`sql localhost "show slave status" | get Master_Log_File`
	read_pos=`sql localhost "show slave status" | get Read_Master_Log_Pos`
	exec_file=`sql localhost "show slave status" | get Relay_Master_Log_File`
	exec_pos=`sql localhost "show slave status" | get Exec_Master_Log_Pos`
	if [ "$read_file" = "$exec_file" ] ; then
		if [ "$read_pos" = "$exec_pos" ] ; then
			break
		fi
	fi
	if $waited ; then
		sql_slave=`sql localhost "show slave status" | get Slave_SQL_Running`
		if [ "$sql_slave" == "Yes" ] ; then
			message "waiting for relay logs to drain $exec_file:$exec_pos to $read_file:$read_pos"
		else
			message "sql slave died - replication errors see logs/database.log"
			break
		fi
	fi
	sleep 10
	echo -n "."
	waited=true
done
if $waited ; then 
	echo ""
fi

#
# it is now safe to mark our node active and start the appserver
# this will start the assassin if needed.
#
message "Starting local Controller"
service appdcontroller start

#
# if the other side was ok, then we can start the service in passive mode
#
if [ "$primary_up" = "true" ] ; then
	if $remote ; then
		message "start passive secondary"
		remservice -nqf $primary appdcontroller start | logonly 2>&1
	fi
fi

if $break_replication ; then
	message "replication has been persistently broken"
	logonly << MESSAGE
Please review the state of each database by examining logs/database.log
and if everything looks good and you are confident with the health of each
database, re-enable replication by running 
replicate.sh -s $primary -E
If unsure, safest way to re-enable replication is to perform full 
replication using replicate.sh -f option to re-establish HA
MESSAGE

fi

#
# call the user hook if one exists - this is a good place to revector a proxy
# or call an API to change DNS, if we want to do that kind of thing
#
if [ -x ./failover_hook.sh ] ; then
	./failover_hook.sh
fi

message "Failover complete at " `date`

exit 0
