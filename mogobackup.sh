#!/bin/bash

aws="/usr/bin/aws"
print="/bin/echo"
date="/bin/date"
find="/bin/find"
mkdir="/bin/mkdir"
logger="/usr/bin/logger"
mongodump="/usr/bin/mongodump"
tar="/bin/tar"

############################################################
# Preferences
############################################################

# how many backups should I retain?
retention=10

# where should I store the backups?
backups="/data/mongo/backup"

# where should I archive the backups?
archive="s3://<bucket_name>"

# Host name (or IP address) of mongo server e.g localhost
DBHOST="127.0.0.1"

# Port that mongo is listening on
DBPORT="27019"

# Backup specific db/dbs
DBNAME=( <db1> <db2> )

# Username and Password
DBUSERNAME=<username>
DBPASSWORD=<password>

# Choose other Server if is Replica-Set Master
REPLICAONSLAVE="yes"

# Allow DBUSERNAME without DBAUTHDB
REQUIREDBAUTHDB="yes"
DBAUTHDB="admin"

# Do we use oplog for point-in-time snapshotting?
#OPLOG="yes"

############################################################
# Environment
############################################################


# get current timestamp
now=`$date '+%Y%m%d%H%M%S'`

## get region from /etc/environment in lowercase
#region=`$print $REGION | $tr '[:upper:]' '[:lower:]'`
#
## get environment from /etc/environment in lowercase
#environment=`$print $ENVIRONMENT | $tr '[:upper:]' '[:lower:]'`
#
## get role from /etc/environment in lowercase
#role=`$print $ROLE | $tr '[:upper:]' '[:lower:]'`

# build aws command with region and output
aws="$aws --debug "

# build backup directory
backups="$backups/"

# build archive directory
archive="$archive/"

# build backup file name
backup="${backups}/mongo_backup_$now.tar.gz"

# build success message
success="INFO: mongo backup successful on ${now}"

# build failure message
failure="ERROR: mongo backup failed on ${now}"


############################################################
# Functions
############################################################
# Database dump function
dbdump () {
    #echo $mongodump --host=$DBHOST:$DBPORT --out="$backups/mongo_backup_$now" -d $1 $OPT
    $mongodump --host=$DBHOST:$DBPORT --out="$backups/mongo_backup_$now" -d $1 $OPT
    [ -e "$backups/mongo_backup_$now" ] && return 0
    echo "$failure on db $1" >&2
    return 1
}

#
# Select first available Secondary member in the Replica Sets and show its
# host name and port.
#
function select_secondary_member {
    # We will use indirect-reference hack to return variable from this function.
    local __return=$1

    # Return list of with all replica set members
    members=( <node1> <node2> <node3> )
    # Check each replset member to see if it's a secondary and return it.
    if [ ${#members[@]} -gt 1 ]; then
        for member in "${members[@]}"; do
            is_secondary=$(mongo --quiet --host $member --eval 'rs.isMaster().secondary')
            case "$is_secondary" in
                'true')     # First secondary wins ...
                    secondary=$member
                    break
                ;;
                'false')    # Skip particular member if it is a Primary.
                    continue
                ;;
                *)          # Skip irrelevant entries.  Should not be any anyway ...
                    continue
                ;;
            esac
        done
    fi

    if [ -n "$secondary" ]; then
        # Ugly hack to return value from a Bash function ...
        eval $__return="'$secondary'"
    fi
}


# Restoring the backup (disabled by default).
# Call the restore function with appropriate parameters.
#.e.g.- restore_backup mongo_backup_$now
restore_backup(){
  #. $1 => uncompressed database backup directory
  tar -xf $backups/$1.tar.gz -C $backups
  mongorestore $backups/$1
}




############################################################
# Options
############################################################
OPT=""                                            # OPT string for use with mongodump

# Do we need to use a username/password?
if [ "$DBUSERNAME" ]; then
    OPT="$OPT --username=$DBUSERNAME --password=$DBPASSWORD"
    if [ "$REQUIREDBAUTHDB" = "yes" ]; then
        OPT="$OPT --authenticationDatabase=$DBAUTHDB"
    fi
fi

# Do we use oplog for point-in-time snapshotting?
if [ "$OPLOG" = "yes" ]; then
    OPT="$OPT --oplog"
fi

# Do we need to backup only a specific database?
#if [ "$DBNAME" ]; then
#  OPT="$OPT -d $DBNAME"
#fi



if [ "x${REPLICAONSLAVE}" == "xyes" ]; then
    # Return value via indirect-reference hack ...
    select_secondary_member secondary

    if [ -n "$secondary" ]; then
        DBHOST=${secondary%%:*}
        DBPORT=${secondary##*:}
    else
        SECONDARY_WARNING="WARNING: No suitable Secondary found in the Replica Sets.  Falling back to ${DBHOST}."
    fi
fi

if [ ! -z "$SECONDARY_WARNING" ]; then
    echo
    echo "$SECONDARY_WARNING"
fi




############################################################
# Main
############################################################

# create backups directory
$mkdir -p $backups


echo
echo Backup of Database Server - $HOST on $DBHOST
echo ======================================================================
echo Backup Start `date`
echo ======================================================================

# backing up mongodb to backups directory
#$mongodump --out $backups/mongo_backup_$now > /dev/null 2>&1
#dbdump

if [ ${#DBNAME[@]} -gt 1 ]; then
        for db in "${DBNAME[@]}"; do
            echo $db
            dbdump $db
        done
    fi

if [ $? -eq 0 ] ; then
  $tar --remove-files -C $backups -cf $backups/mongo_backup_$now.tar.gz mongo_backup_$now
  $logger -i $success -t "backups"
else
  $logger -i $failure -t "backups" && exit 1
fi


echo ======================================================================
echo Backup End Time `date`
echo ======================================================================

# prune backups older than x days
$find $backups -mtime +$retention -exec rm {} >/dev/null 2>&1 \;

# sync backups to archive location
echo "$aws s3 sync $backups $archive --delete "
$aws s3 sync $backups $archive --delete >/dev/null 2>&1
echo aws $?

############################################################
# Exit
############################################################
exit 0
