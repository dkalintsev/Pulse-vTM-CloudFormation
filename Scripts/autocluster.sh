#!/bin/bash
#
# Copyright (c) 2018 Pulse Secure LLC.
#
# This script is customised during vADC instance deployment by cfn-init
# Please see example usage in the CloudFormation template:
# https://github.com/dkalintsev/Pulse-vTM-CloudFormation/blob/v1.0.0/vTM-cluster-existing-VPC.template#L415
#
# The purpose of this script is to form a new vADC cluster or join an existing one.
#
# We expect the following vars passed in:
# ClusterID = AWS EC2 tag used to find vADC instances in our cluster
# Verbose = "Yes|No" - this controls whether we print extensive log messages as we go.
#
# vADC instances running this script will need to have an IAM Role with the Policy allowing:
# - ec2:DescribeInstances
# - ec2:CreateTags
# - ec2:DeleteTags
#
export PATH=$PATH:/usr/local/bin
logFile="/var/log/autocluster.log"

clusterID="{{ClusterID}}"

# This expects that admin password was passed into UserData without spaces around "="
adminPass=$(curl -s http://169.254.169.254/latest/user-data | tr " " '\n' | awk -F= '/^pass/ {print $2}')

verbose="{{Verbose}}"

# Tags for Cluster and Elections
stateTag="ClusterState"
electionTag="ElectionState"
licensingTag="LicensingStatus"

# Values for Cluster
statusActive="Active"
statusJoining="Joining"

# Value for Elections
statusForming="Forming"

# Value for Licensing
statusLicUnlicensed="NoLicense"
statusLicWaiting="WaitingForLicense"
statusLicLicensed="Licensed"
statusLicTimedout="TimedOutWaiting"

# Random string for /tmp files
rand_str=$(cat /dev/urandom | env LC_CTYPE=C tr -cd 'a-f0-9' | head -c 10)

resFName="/tmp/aws-out.$rand_str"
jqResFName="/tmp/jq-out.$rand_str"
awscliLogF="/var/log/autocluster-out.log"
waitForCmdF="/tmp/waitFor-cmd.$rand_str"

export ZEUSHOME=/opt/zeus
selfReg="/opt/zeus/zxtm/bin/self-register"

if [[ "$verbose" == "" ]]; then
    # there's no such thing as too much logging ;)
    verbose="Yes"
fi

cleanup  () {
    rm -f $resFName $jqResFName
    rm -f $waitForCmdF
}

trap cleanup EXIT

logMsg () {
    if [[ "$verbose" =~ ^[Yy] ]]; then
        ts=$(date -u +%FT%TZ)
        echo "$ts $0[$$]: $*" >> $logFile
    fi
}

# We need jq, which should have been installed by now.
which jq >/dev/null 2>&1
if [[ "$?" != "0" ]]; then
    logMsg "001: Looks like jq isn't installed; quiting."
    exit 1
fi

# We also need aws cli tools.
which aws >/dev/null 2>&1
if [[ "$?" != "0" ]]; then
    logMsg "002: Looks like AWS CLI tools isn't installed; quiting."
    exit 1
fi

# When ASG starts multiple vADC instances, it's probably better to pace ourselves out.
backoff=$RANDOM
let "backoff %= 30"
sleep $backoff

myInstanceID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

region=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)

# Execute AWS CLI command "safely": if error occurs - backoff exponentially
# If succeeded - return 0 and save output, if any, in $resFName
# Given this script runs once only, the "failure isn't an option".
# So this func will block till the cows come home.
#
safe_aws () {
    errCode=1
    backoff=0
    retries=0
    while [[ "$errCode" != "0" ]]; do
        let "backoff = 2**retries"
        if (( $retries > 5 )); then
            # Exceeded retry budget of 5.
            # Doing random sleep up to 45 sec, then back to try again.
            backoff=$RANDOM
            let "backoff %= 45"
            logMsg "003: safe_aws \"$*\" exceeded retry budget. Sleeping for $backoff second(s), then back to work.."
            sleep $backoff
            retries=0
            backoff=1
        fi
        aws $* > $resFName 2>>$awscliLogF
        errCode=$?
        if [[ "$errCode" != "0" ]]; then
            logMsg "004: AWS CLI returned error $errCode; sleeping for $backoff seconds.."
            sleep $backoff
            let "retries += 1"
        fi
        # We are assuming that aws cli produced valid JSON output or "".
        # While this is thing worth checking, we'll just leave it alone for now.
        # jq '.' $resFName > /dev/null 2>&1
        # errCode=$?
    done
    return 0
}

# Set tag on $myInstanceID
# $1 = tag
# $2 = value
#
setTag () {
    logMsg "005: Setting tags on $myInstanceID: \"$1:$2\""
    safe_aws ec2 create-tags --region $region \
        --resources $myInstanceID \
        --tags Key=$1,Value=$2
    # Check if I can find myself by the newly applied tag
    declare -a stList
    unset stList
    while [[ ${#stList[*]} == 0 ]]; do
        findTaggedInstances $1 $2
        stList=( $(cat $jqResFName | grep "$myInstanceID") )
        logMsg "006: Checking tagged instances \"$1:$2\", expecting to see $myInstanceID; got \"$stList\""
        if [[ ${#stList[*]} == 1 ]]; then
            logMsg "007: Found us, we're done."
        else
            logMsg "008: Not yet; sleeping for a bit."
            sleep 3
        fi
    done
    return 0
}

# Remove tag from $myInstanceID
# $1 = tag
# $2 = value (need for success checking)
#
delTag () {
    logMsg "009: Deleting tags: \"$1:$2\""
    safe_aws ec2 delete-tags --region $region \
        --resources $myInstanceID \
        --tags Key=$1
    # Check if we don't come up when searching for the tag, i.e., tag is gone
    declare -a stList
    stList=( blah )
    while [[ ${#stList[*]} -gt 0 ]]; do
        findTaggedInstances $1 $2
        stList=( $(cat $jqResFName | grep "$myInstanceID") )
        logMsg "010: Checking tagged instances \"$1:$2\", expecting NOT to see $myInstanceID; got \"$stList\""
        if [[ ${#stList[*]} == 0 ]]; then
            logMsg "011: Tag \"$1:$2\" is not there, we're done."
        else
            logMsg "012: Not yet; sleeping for a bit."
            sleep 3
        fi
    done
    return 0
}

# Returns list of instances with matching tags
# $1 tag
# $2 value
#
findTaggedInstances () {
    # We operate only on instances that are both
    # "running" and have "ClusterID" = $clusterID
    filter="Name=tag:ClusterID,Values=$clusterID \
            Name=instance-state-name,Values=running"

    # if we're given tag and value, look for these; if not - just return running instances with our ClusterID
    if [ $# -eq "2" ]; then
        filter=$filter" Name=tag:$1,Values=$2"
    fi

    # Run describe-instances and make sure we get valid JSON (which includes empty file)
    safe_aws ec2 describe-instances --region $region \
        --filters $filter --output json
    cat $resFName | jq -r ".Reservations[].Instances[].InstanceId" > $jqResFName
    return 0
}

# Returns private IP of an instance by instance-id
# $1 instance-id
#
getInstanceIP () {
    safe_aws ec2 describe-instances --region $region \
        --instance-id $1 --output json
    cat $resFName | jq -r ".Reservations[].Instances[].NetworkInterfaces[].PrivateIpAddress" > $jqResFName
    return 0
}

# function getLock - makes sure we're the only running instance with the
# $stateTag == Tag passed to us as function parameter
#
# $1 & $2 = tag & value to lock on for myInstanceID
getLock () {
    declare -a list
    while true; do
        list=( blah )
        # Get a list of instances with $stateTag = $tag
        # if there are any, wait 5 seconds, then retry until there are none
        while [[ ${#list[*]} -gt 0 ]]; do
            logMsg "013: Looping until there's no instance matching \"$1:$2\""
            findTaggedInstances $1 $2
            list=( $(cat $jqResFName | grep -v $myInstanceID) )
            if [[ ${#list[*]} -gt 0 ]]; then
                s_list=$(echo ${list[@]/%/,} | sed -e "s/,$//g")
                logMsg "014: Found some: \"$s_list\", sleeping..."
                sleep 5
            fi
        done
        # Do we already have the tag by chance?
        list=( $(cat $jqResFName | grep "$myInstanceID") )
        if [[ ${#list[*]} == 1 ]]; then
            logMsg "015: We already have that tag, returning."
            return 0
        fi
        # once there aren't any, tag ourselves
        logMsg "016: Tagging ourselves: \"$1:$2\""
        setTag $1 $2
        list=( blah )
        # check if there are other tagged instances who managed to beat us to it
        while [[ ${#list[*]} -gt 0 ]]; do
            findTaggedInstances $1 $2
            list=( $(cat $jqResFName | grep -v "$myInstanceID") )
            s_list=$(echo ${list[@]/%/,} | sed -e "s/,$//g")
            logMsg "017: Looking for others with the same tags, found: \"$s_list\""
            if [[ ${#list[*]} -gt 0 ]]; then
                # there's someone else - clash
                logMsg "018: Clash detected, calling delTag: \"$1:$2\""
                delTag $1 $2
                backoff=$RANDOM
                let "backoff %= 25"
                # do random backoff, then bail to the mail while().
                logMsg "019: Backing off for $backoff seconds"
                sleep $backoff
                unset list
            else
                # lock obtained; we're done here.
                logMsg "020: Got our lock, returning."
                return 0
            fi
        done
    done
}

# Attempt to run $waitForCmdF as a script; try until successful.
# $1 = friendly name for the command being run
#
waitFor () {
    errCode=1
    backoff=0
    retries=0
    chmod +x $waitForCmdF
    while [[ "$errCode" != "0" ]]; do
        let "backoff = 2**retries"
        if (( $retries > 5 )); then
            # Exceeded retry budget of 5.
            # Doing random sleep up to 45 sec, then back to try again.
            backoff=$RANDOM
            let "backoff %= 45"
            logMsg "021: waitFor \"$1\" exceeded retry budget. Sleeping for $backoff second(s), then back to work.."
            sleep $backoff
            retries=0
            backoff=1
        fi
        date >> /tmp/waitFor.log
        $waitForCmdF >> /tmp/waitFor.log 2>&1
        errCode=$?
        if [[ "$errCode" != "0" ]]; then
            logMsg "022: $1 returned error $errCode; sleeping for $backoff seconds.."
            sleep $backoff
            let "retries += 1"
        fi
    done
    return 0
}

updateRemoteLicensingKeys () {
    # This function expects that the following keys have been set in the
    # EC2 UserData, which will then map to the REST API call parameters:
    #
    # UserData -> REST Param:
    # "owner" -> "owner"
    # "owner_secret" -> "owner_secret"
    # "not_sd_address" -> "registration_server" <= NOTE the "not_" in front;
    # +                                            this is to stop automatic
    # +                                            self-register on deploy
    # "sd_cert" -> "server_certificate"
    # "registration_policy" -> "policy_id"
    #
    # We extract values for these keys, and build a REST API call to configure
    # the vTM we're on (this should be the first vTM in the cluster).

    userData=$(curl -s http://169.254.169.254/latest/user-data | tr " " '\n')

    myOwner=$(echo "$userData" | awk -F= '/^owner=/ {print $2}' | tr -d \")
    myOwnerSecret=$(echo "$userData" | awk -F= '/^owner_secret=/ {print $2}' | tr -d \")
    mySdAddress=$(echo "$userData" | awk -F= '/^not_sd_address=/ {print $2}' | tr -d \")
    myRegPolicy=$(echo "$userData" | awk -F= '/^registration_policy=/ {print $2}' | tr -d \")

    # Cert has "=" signs in it, so can't do as above. ;)
    mySdCert=$(echo "$userData" | awk '/^sd_cert=/ {print}' | tr -d \" | cut -d= -f2-)

    requestJson=$(printf '{"properties":{"remote_licensing":{"owner":"%s","owner_secret":"%s","policy_id":"%s","registration_server":"%s","server_certificate":"%s"}}}' \
        $myOwner \
        $myOwnerSecret \
        $myRegPolicy \
        $mySdAddress \
        $mySdCert)

    if [[ "$mySdAddress" != "" ]]; then
        # Only update if there was an SD address given in UserData
        echo '#!/bin/bash' > $waitForCmdF
        echo "curl -s -u admin:${adminPass} -X PUT -H \"Content-Type: application/json\" \
            -d '$requestJson' \
            http://localhost:9070/api/tm/4.0/config/active/global_settings" >> $waitForCmdF
        waitFor "Update Global Settings"
    fi

    return 0
}

sefRegIfNecessary () {
    # Check if vTM is configured for Services Director self-registration
    regSrv=$(curl -s -u admin:${adminPass} \
    http://localhost:9070/api/tm/4.0/config/active/global_settings \
        | jq -r '.properties.remote_licensing.registration_server')

    # The above would return an <address>:<port> of an SD, if configured
    if [[ "${regSrv}" != "" ]]; then
        # If it is set, then we need to run self-registration request
        logMsg "023: Running ${selfReg}"
        setTag "$licensingTag" "$statusLicWaiting"
        echo '#!/bin/bash' > $waitForCmdF
        echo "${selfReg}" >> $waitForCmdF
        waitFor "Self-Register"

        logMsg "024: Waiting for the license to arrive"
        retries=0
        licStatus="License not found"
        # Do 7 attempts, for the total max time of 127 seconds
        while [[ "$licStatus" == "License not found" && "$retries" -lt 7 ]]; do
            logMsg "025: Sleeping for $(( 2** retries )) seconds before (re) trying check for valid license.."
            sleep $(( 2**retries ))
            licStatus=$(curl -s http://localhost:9080/zxtm/getexternalfeatures -H "Commkey: $(cat ${ZEUSHOME}/zxtm/conf/commkey)")
            if [[ "$licStatus" == "License not found" ]]; then
                (( retries += 1 ))
            fi
        done
        if [[ "$licStatus" == "License not found" ]]; then
            # Ran out of retries
            #
            # There's still chance that the license will arrive later, but
            # we'll carry on with the "TimedOutWaiting" tag to help Ops to
            # detect there's potentiall a "slow SD" problem
            #
            logMsg "026: Ran out of retries; proceeding as $statusLicTimedout"
            setTag "$licensingTag" "$statusLicTimedout"
        else
            # We're good
            logMsg "027: Successfully received a license from the SD."
            setTag "$licensingTag" "$statusLicLicensed"
        fi
    fi
    return 0
}

runElections () {
    # Obtain a lock on $statusForming
    logMsg "028: Starting elections; trying to get lock on tag $electionTag with $statusForming"
    # Check if there's another instance that's currently "Forming"
    findTaggedInstances $stateTag $statusForming
    list=( $(cat $jqResFName) )
    if [[ ${#list[*]} -gt 0 ]]; then
        # This is most likely due to that other instance sitting there waiting
        # for its license to arrive from Services Director
        logMsg "029: There's an another instance that's busy Forming. Bailing on elections."
        sleep 2
        return 1
    fi
    # Just in case - if there was previous unsuccessful run
    getLock "$electionTag" "$statusForming"
    logMsg "030: Election tag locked; checking if anyone sneaked past us into $statusActive"
    declare -a list
    # Check if there's anyone already $statusActive
    findTaggedInstances $stateTag $statusActive
    list=( $(cat $jqResFName) )
    if [[ ${#list[*]} -gt 0 ]]; then
        # Clear $statusForming and bail
        logMsg "031: Looks like someone beat us to it somehow. Bailing on elections."
        delTag $electionTag $statusForming
        return 1
    else
        # Ok, looks like we're clear to proceed
        logMsg "032: We won elections, setting ourselves $statusActive"

        updateRemoteLicensingKeys
        sefRegIfNecessary

        setTag "$stateTag" "$statusActive"
        delTag "$electionTag" "$statusForming"
        return 0
    fi
}

# Join the cluster. Prerequisites for this func:
# 1. Main loop detected there's an instance in $statusActive
# 2. $jqResFName has the list of $statusActive instances
#
joinCluster () {
    logMsg "033: Starting cluster join.."
    declare -a jList
    # Are there instances where $stateTag == $statusActive?
    # There should be since this is how we got here, but let's make double sure.
    # Main loop already did findTaggedInstances, so let's reuse result.
    jList=( $(cat $jqResFName) )
    logMsg "034: Getting lock on $stateTag $statusJoining"
    getLock "$stateTag" "$statusJoining"
    num=$RANDOM
    let "num %= ${#jList[*]}"
    instanceToJoin=${jList[$num]}
    getInstanceIP $instanceToJoin
    node=$(cat $jqResFName)
    logMsg "035: Picked the node to join: \"$node\""
    logMsg "036: Creating and running cluster join script"
    # doing join
    #
    # Note: changed from Join TIPs = Yes to No (arg after {fp})
    # We expect that external cluster config manager would update the
    # $machines in TIP groups when it detects new vTMs.
    #
    tmpf="/tmp/dojoin.$rand_str"
    rm -f $tmpf
    cat > $tmpf << EOF
#!/bin/sh

ZEUSHOME=/opt/zeus
export ZEUSHOME=/opt/zeus
exec \$ZEUSHOME/perl/miniperl -wx \$0 \${1+"\$@"}

#!perl -w
#line 9

BEGIN {
    unshift @INC
        , "\$ENV{ZEUSHOME}/zxtm/lib/perl"
        , "\$ENV{ZEUSHOME}/zxtmadmin/lib/perl"
        , "\$ENV{ZEUSHOME}/perl"
}

use Zeus::ZXTM::Configure;

MAIN: {

    my \$clusterTarget = '$node:9090';
    my %certs = Zeus::ZXTM::Configure::CheckSSLCerts( [ \$clusterTarget ] );
    my \$ret = Zeus::ZXTM::Configure::RegisterWithCluster (
        "admin",
        "$adminPass",
        [ \$clusterTarget ],
        undef,
        { \$clusterTarget => \$certs{\$clusterTarget}->{fp} },
        "No",
        undef,
        "Yes"
    );

    if( \$ret == 0 ) {
        exit(1);
    }
}
EOF
    chmod +x $tmpf

    # No point trying to join the cluster if node isn't ready
    echo '#!/bin/bash' > $waitForCmdF
    echo "curl -s -k -u admin:${adminPass} https://${node}:9090" >> $waitForCmdF
    waitFor "Check Cluster Ready"

    $tmpf >> $awscliLogF 2>&1
    errCode="$?"
    if [[ "$errCode" != "0" ]]; then
        logMsg "037: Some sort of error ($errCode) happened attempting to join the cluster, let's keep trying.."
        rm -f $tmpf
        return 1
    else
        logMsg "038: Join operation successful, returning to the main loop."
        rm -f $tmpf
        return 0
    fi
}

# We should not start doing anything if vTM isn't in a running state.
# Let's check it by seeing if /opt/zeus/log/errors exists and isn't empty -
# it's created when vTM software starts. We'll wait util it's so.
#
echo '#!/bin/bash' > $waitForCmdF
echo "test -s ${ZEUSHOME}/log/errors" >> $waitForCmdF
waitFor "Wait for vTM to start"

# Sanity check: can we find ourselves in "running" state?
#
findTaggedInstances
declare -a stList
stList=( $(cat $jqResFName | grep "$myInstanceID") )
if [[ ${#stList[*]} == 0 ]]; then
    logMsg "039: Cant't seem to be able to find ourselves running; did you set ClusterID correctly? I have: \"$clusterID\". Bailing."
    exit 1
fi

# Let's check if we're already in $statusActive state, so as not to waste time.
#
findTaggedInstances $stateTag $statusActive
declare -a list
list=( $(cat $jqResFName | grep $myInstanceID) )
s_list=$(echo ${list[@]/%/,} | sed -e "s/,$//g")
logMsg "040: Checking if we are already $statusActive; got: \"$s_list\""
if [[ ${#list[*]} -gt 0 ]]; then
    logMsg "041: Looks like we've nothing more to do; exiting."
    exit 0
else
    logMsg "042: Welp, we've got work to do."
fi

logMsg "043: Entering main loop.."

# We start unlicensed
setTag "$licensingTag" "$statusLicUnlicensed"

while true; do
    # Main loop
    declare -a list
    # Is/are there are instances where $stateTag == $statusActive?
    findTaggedInstances $stateTag $statusActive
    list=( $(cat $jqResFName) )
    s_list=$(echo ${list[@]/%/,} | sed -e "s/,$//g")
    logMsg "044: Checking for $statusActive vTMs; got: \"$s_list\""
    if [[ ${#list[*]} -gt 0 ]]; then
        logMsg "045: There are active node(s), starting join process."
        joinCluster
        if [[ "$?" == "0" ]]; then
            sefRegIfNecessary
            logMsg "046: Join successful, setting ourselves $statusActive.."
            setTag "$stateTag" "$statusActive"
            exit 0
        else
            logMsg "047: Join failed; returning to the main loop."
        fi
    else
        logMsg "048: No active cluster members; starting elections"
        runElections
        if [[ "$?" == "0" ]]; then
            logMsg "049: Won elections, we're done here."
            exit 0
        else
            logMsg "050: Lost elections; returning to the main loop."
        fi
    fi
done

