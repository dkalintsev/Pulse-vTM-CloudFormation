#!/bin/bash
#
# Copyright (c) 2018 Pulse Secure LLC.
#
# This script is customised during vADC instance deployment by cfn-init
# Please see example usage in the CloudFormation template:
# https://github.com/dkalintsev/Pulse-vTM-CloudFormation/blob/v1.0.0/vTM-cluster-existing-VPC.template#L427
#
# The purpose of this script is to perform housekeeping on a running vADC cluster:
# - Remove vADC nodes that aren't in "running" state
# - Add or remove secondary private IPs to vADC node to match number of configured Traffic IPs in the cluster
#   * this is to help deal with Traffic IPs as each EIP needs a secondary private IP
#
# We expect the following vars passed in:
# ClusterID = AWS EC2 tag used to find vADC instances in our cluster
# Region = AWS::Region
# Verbose = "Yes|No" - this controls whether we print extensive log messages as we go.
#
# vADC instances running this script will need to have an IAM Role with the Policy allowing:
# - ec2:DescribeInstances
# - ec2:CreateTags
# - ec2:DeleteTags
#
export PATH=$PATH:/usr/local/bin
export ZEUSHOME=/opt/zeus
logFile="/var/log/housekeeper.log"
configDir="/opt/zeus/zxtm/conf/zxtms"
configSync="/opt/zeus/zxtm/bin/replicate-config"

clusterID="{{ClusterID}}"
#region="{{Region}}" ## Replaced by call to metadata server - see region=$() below
verbose="{{Verbose}}"

# Tag for Housekeeping
housekeeperTag="HousekeepingState"

# Value for when running Housekeeping
statusWorking="Working"

# Creating temp filenames to keep lists of running and clustered instances, and delta between the two.
#
rand_str=$(cat /dev/urandom | env LC_CTYPE=C tr -cd 'a-f0-9' | head -c 10)
runningInstF="/tmp/running.$rand_str"
clusteredInstF="/tmp/clustered.$rand_str"
deltaInstF="/tmp/delta.$rand_str"
filesF="/tmp/files.$rand_str"
resFName="/tmp/aws-out.$rand_str"
jqResFName="/tmp/jq-out.$rand_str"
awscliLogF="/var/log/housekeeper-out.log"
dnsIPs="/tmp/dnsIPs.$rand_str"
activeIPs="/tmp/activeIPs.$rand_str"
changeSetF="/tmp/changeSetF.$rand_str"

lockF=/tmp/housekeeper.lock
leaveLock="0"

cleanup  () {
    rm -f $runningInstF $clusteredInstF $deltaInstF $filesF
    rm -f $resFName $jqResFName
    rm -f $dnsIPs $activeIPs $changeSetF
    if [[ "$leaveLock" = "0" ]]; then
        rm -f $lockF
    fi
}

trap cleanup EXIT

logMsg () {
    if [[ "$verbose" =~ ^[Yy] ]]; then
        ts=$(date -u +%FT%TZ)
        echo "$ts $0[$$]: $*" >> $logFile
    fi
}

if [[ "$verbose" == "" ]]; then
    # there's no such thing as too much logging ;)
    verbose="Yes"
fi

if [[ -f $lockF ]]; then
    logMsg "001: Found lock file, exiting."
    leaveLock="1"
    exit 1
fi

# We need jq, which should have been installed by now.
which jq >/dev/null 2>&1
if [[ "$?" != "0" ]]; then
    logMsg "002: Looks like jq isn't installed; quiting."
    exit 1
fi

# We also need aws cli tools.
which aws >/dev/null 2>&1
if [[ "$?" != "0" ]]; then
    logMsg "003: Looks like AWS CLI tools isn't installed; quiting."
    exit 1
fi

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
            logMsg "004: safe_aws \"$*\" exceeded retry budget. Sleeping for $backoff second(s), then back to work.."
            sleep $backoff
            retries=0
            backoff=1
        fi
        aws $* > $resFName 2>>$awscliLogF
        errCode=$?
        if [[ "$errCode" != "0" ]]; then
            logMsg "005: AWS CLI returned error $errCode; sleeping for $backoff seconds.."
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

# First, do random sleep to avoid race with other cluster nodes, since we're running from cron.
#
backoff=$RANDOM
let "backoff %= 25"
logMsg "006: Running initial backoff for $backoff seconds"
sleep $backoff

cleanup
touch $lockF

if [[ -f /tmp/autocluster.sh ]]; then
    logMsg "007: Found /tmp/autocluster.sh; running it.."
    /tmp/autocluster.sh > /tmp/autocluster-out.log 2>&1
    rm -f /tmp/autocluster.sh
    logMsg "008: /tmp/autocluster.sh finished and removed."
fi

declare -a list

# Make sure this instance has the right number of private IP addresses - as many as there are
# Traffic IPs assigned to all TIP Groups
#
# Sample output we're working on:
# ip-10-8-2-115:~# echo 'TrafficIPGroups.getTrafficIPGroupNames' | /usr/bin/zcli 
# ["Web VIP"]
# ip-10-8-2-115:~# echo 'TrafficIPGroups.getIPAddresses "Web VIP"' | /usr/bin/zcli 
# ["13.54.192.46","54.153.152.253"]
#
# Get configured TIP Groups
tipArray=( )
zresponse=$(echo 'TrafficIPGroups.getTrafficIPGroupNames' | /usr/bin/zcli)
if [[ "$?" == 0 ]]; then
    IFS='[]",' read -r -a tmpArray <<< "$zresponse"
    for i in "${!tmpArray[@]}"; do
        if [[ ${tmpArray[i]} != "" ]]; then
            tipArray+=( "${tmpArray[i]}" );
        fi
    done
    unset tmpArray
    s_list=$(echo ${tipArray[@]/%/,} | sed -e "s/,$//g")
    logMsg "009: Got Traffic IP groups: \"$s_list\""
else
    logMsg "010: Error getting Traffic IP Groups; perhaps none configured yet"
fi

# Iterate over TIP Groups we found; count the total number of TIPs in all of them
#
numTIPs=0
for tipGroup in "${!tipArray[@]}"; do
    zresponse=$(echo "TrafficIPGroups.getIPAddresses \"${tipArray[$tipGroup]}\"" | /usr/bin/zcli)
    if [[ "$?" == 0 ]]; then
        IFS='[]",' read -r -a tmpArray <<< "$zresponse"
        for i in "${!tmpArray[@]}"; do
            if [[ ${tmpArray[i]} != "" ]]; then
                tipIPArray+=( "${tmpArray[i]}" );
            fi
        done
        unset tmpArray
        if [[ ${#tipIPArray[*]} != 0 ]]; then
            let "numTIPs += ${#tipIPArray[*]}"
        fi
        s_list=$(echo ${tipIPArray[@]/%/,} | sed -e "s/,$//g")
        logMsg "011: Got Traffic IPs for TIP Group \"${tipArray[$tipGroup]}\": \"$s_list\"; numTIPs is now $numTIPs"
    else
        logMsg "012: Error getting Traffic IPs from TIP Group \"${tipArray[$tipGroup]}\""
    fi
done

# We would like to always have at least two secondary IPs available, to ensure
# configuration for a typical scenario with 2 x TIPs works successfully.
# If we don't do this, vADC cluster may sit in "Error" state until the next housekeeper run
# after a first TIP Group has been created.
#
# AWS Docs reference on instance types and secondary IPs:
# http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-eni.html#AvailableIpPerENI
#
if [[ $numTIPs < 2 ]]; then
    numTIPs=2
fi

# Get a JSON for ourselves in $resFName
safe_aws ec2 describe-instances --region $region \
    --instance-id $myInstanceID --output json

# Get my InstanceType to check if we're not trying to grab more IPs than possible
instanceType=$(cat $resFName | \
    jq -r ".Reservations[].Instances[].InstanceType")

case $instanceType in
    c1.medium)
    maxPIPs=6
    ;;
    c1.xlarge)
    maxPIPs=15
    ;;
    c3.large)
    maxPIPs=10
    ;;
    c3.xlarge)
    maxPIPs=15
    ;;
    c3.2xlarge)
    maxPIPs=15
    ;;
    c3.4xlarge)
    maxPIPs=30
    ;;
    c3.8xlarge)
    maxPIPs=30
    ;;
    c4.large)
    maxPIPs=10
    ;;
    c4.xlarge)
    maxPIPs=15
    ;;
    c4.2xlarge)
    maxPIPs=15
    ;;
    c4.4xlarge)
    maxPIPs=30
    ;;
    c4.8xlarge)
    maxPIPs=30
    ;;
    c5.large)
    maxPIPs=10
    ;;
    c5.xlarge)
    maxPIPs=15
    ;;
    c5.2xlarge)
    maxPIPs=15
    ;;
    c5.4xlarge)
    maxPIPs=30
    ;;
    c5.9xlarge)
    maxPIPs=30
    ;;
    c5.18xlarge)
    maxPIPs=50
    ;;
    cc2.8xlarge)
    maxPIPs=30
    ;;
    cg1.4xlarge)
    maxPIPs=30
    ;;
    cr1.8xlarge)
    maxPIPs=30
    ;;
    d2.xlarge)
    maxPIPs=15
    ;;
    d2.2xlarge)
    maxPIPs=15
    ;;
    d2.4xlarge)
    maxPIPs=30
    ;;
    d2.8xlarge)
    maxPIPs=30
    ;;
    f1.2xlarge)
    maxPIPs=15
    ;;
    f1.16xlarge)
    maxPIPs=50
    ;;
    g2.2xlarge)
    maxPIPs=15
    ;;
    g2.8xlarge)
    maxPIPs=30
    ;;
    g3.4xlarge)
    maxPIPs=30
    ;;
    g3.8xlarge)
    maxPIPs=30
    ;;
    g3.16xlarge)
    maxPIPs=50
    ;;
    hs1.8xlarge)
    maxPIPs=30
    ;;
    i2.xlarge)
    maxPIPs=15
    ;;
    i2.2xlarge)
    maxPIPs=15
    ;;
    i2.4xlarge)
    maxPIPs=30
    ;;
    i2.8xlarge)
    maxPIPs=30
    ;;
    i3.large)
    maxPIPs=10
    ;;
    i3.xlarge)
    maxPIPs=15
    ;;
    i3.2xlarge)
    maxPIPs=15
    ;;
    i3.4xlarge)
    maxPIPs=30
    ;;
    i3.8xlarge)
    maxPIPs=30
    ;;
    i3.16xlarge)
    maxPIPs=50
    ;;
    m1.small)
    maxPIPs=4
    ;;
    m1.medium)
    maxPIPs=6
    ;;
    m1.large)
    maxPIPs=10
    ;;
    m1.xlarge)
    maxPIPs=15
    ;;
    m2.xlarge)
    maxPIPs=15
    ;;
    m2.2xlarge)
    maxPIPs=30
    ;;
    m2.4xlarge)
    maxPIPs=30
    ;;
    m3.medium)
    maxPIPs=6
    ;;
    m3.large)
    maxPIPs=10
    ;;
    m3.xlarge)
    maxPIPs=15
    ;;
    m3.2xlarge)
    maxPIPs=30
    ;;
    m4.large)
    maxPIPs=10
    ;;
    m4.xlarge)
    maxPIPs=15
    ;;
    m4.2xlarge)
    maxPIPs=15
    ;;
    m4.4xlarge)
    maxPIPs=30
    ;;
    m4.10xlarge)
    maxPIPs=30
    ;;
    m4.16xlarge)
    maxPIPs=30
    ;;
    p2.xlarge)
    maxPIPs=15
    ;;
    p2.8xlarge)
    maxPIPs=30
    ;;
    p2.16xlarge)
    maxPIPs=30
    ;;
    p3.2xlarge)
    maxPIPs=15
    ;;
    p3.8xlarge)
    maxPIPs=30
    ;;
    p3.16xlarge)
    maxPIPs=30
    ;;
    r3.large)
    maxPIPs=10
    ;;
    r3.xlarge)
    maxPIPs=15
    ;;
    r3.2xlarge)
    maxPIPs=15
    ;;
    r3.4xlarge)
    maxPIPs=30
    ;;
    r3.8xlarge)
    maxPIPs=30
    ;;
    r4.large)
    maxPIPs=10
    ;;
    r4.xlarge)
    maxPIPs=15
    ;;
    r4.2xlarge)
    maxPIPs=15
    ;;
    r4.4xlarge)
    maxPIPs=30
    ;;
    r4.8xlarge)
    maxPIPs=30
    ;;
    r4.16xlarge)
    maxPIPs=50
    ;;
    t1.micro)
    maxPIPs=2
    ;;
    t2.nano)
    maxPIPs=2
    ;;
    t2.micro)
    maxPIPs=2
    ;;
    t2.small)
    maxPIPs=4
    ;;
    t2.medium)
    maxPIPs=6
    ;;
    t2.large)
    maxPIPs=12
    ;;
    t2.xlarge)
    maxPIPs=15
    ;;
    t2.2xlarge)
    maxPIPs=15
    ;;
    x1.16xlarge)
    maxPIPs=30
    ;;
    x1.32xlarge)
    maxPIPs=30
    ;;
    x1e.xlarge)
    maxPIPs=10
    ;;
    x1e.2xlarge)
    maxPIPs=15
    ;;
    x1e.4xlarge)
    maxPIPs=15
    ;;
    x1e.8xlarge)
    maxPIPs=15
    ;;
    x1e.16xlarge)
    maxPIPs=30
    ;;
    x1e.32xlarge)
    maxPIPs=30
    ;;
esac

# One of the private IPs is used for primary; decreasing maxPIPs by 1.
let "m = $maxPIPs - 1"
maxPIPs=$m

if (( "$numTIPs" > "$maxPIPs" )); then
    logMsg "013: Asking for more private IPs (${numTIPs}) than our instance type ${instanceType} supports (${maxPIPs}); caping it."
    numTIPs="$maxPIPs"
fi

myLocalIP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

# What's the ENI ID of my eth0? We'll need it to add/remove private IPs.
# Find .NetworkInterfaces where .PrivateIpAddresses[].PrivateIpAddress = $myLocalIP,
# then extract the .NetworkInterfaceId
eniID=$(cat $resFName | \
    jq -r ".Reservations[].Instances[].NetworkInterfaces[] | \
    select(.PrivateIpAddresses[].PrivateIpAddress==\"$myLocalIP\") | \
    .NetworkInterfaceId")

# Let's see how many secondary IP addresses I already have
declare -a myPrivateIPs
myPrivateIPs=( $(cat $resFName | \
    jq -r ".Reservations[].Instances[].NetworkInterfaces[] | \
    select(.NetworkInterfaceId==\"$eniID\") | \
    .PrivateIpAddresses[] | \
    select(.Primary==false) | \
    .PrivateIpAddress") )

# Compare the number of my secondary private IPs with the number of TIPs in my cluster
if [[ "${#myPrivateIPs[*]}" != "$numTIPs" ]]; then
    # There's a difference; we need to adjust
    logMsg "014: Need to adjust the number of private IPs. Have: ${#myPrivateIPs[*]}, need: $numTIPs"
    if (( $numTIPs > ${#myPrivateIPs[*]} )); then
        # Need to add IPs
        let "delta = $numTIPs - ${#myPrivateIPs[*]}"
        logMsg "015: Adding $delta private IPs to ENI $eniID"
        safe_aws ec2 assign-private-ip-addresses \
            --region $region \
            --network-interface-id $eniID \
            --secondary-private-ip-address-count $delta
    else
        # Need to remove IPs
        # First let's find out which one(s) don't have EIP associated, as we can only remove those.
        declare -a myFreePrivateIPs
        myFreePrivateIPs=( $(cat $resFName | \
            jq -r ".Reservations[].Instances[].NetworkInterfaces[] | \
            select(.NetworkInterfaceId==\"$eniID\") | \
            .PrivateIpAddresses[] | \
            select(.Primary==false) | \
            select (.Association.PublicIp==null) | \
            .PrivateIpAddress") )
        let "delta = ${#myPrivateIPs[*]} - $numTIPs"
        # If we need to remove more IPs than we have without EIPs, then only remove those we can
        if (( $delta > ${#myFreePrivateIPs[*]} )); then
            logMsg "016: Need to delete $delta, but can only do ${#myFreePrivateIPs[*]}; the rest is tied with EIPs."
            delta=${#myFreePrivateIPs[*]}
        fi
        for ((i=0; i < $delta; i++)); do
            num=$RANDOM
            let "num %= ${#myFreePrivateIPs[*]}"
            ipToDelete=${myFreePrivateIPs[$num]}
            let "j = i + 1"
            logMsg "017: Deleting IP $j of $delta - $ipToDelete from ENI $eniID"
            # Not using "safe_aws" here; it's OK to fail - we'll just retry the next time round.
            aws ec2 unassign-private-ip-addresses \
                --region $region \
                --network-interface-id $eniID \
                --private-ip-addresses $ipToDelete 2>>$awscliLogF
            sleep 3
        done
    fi
    logMsg "018: Done adjusting private IPs."
else
    logMsg "019: No need to adjust private IPs."
fi

# Get the cluster master vTM
#
firstWorking=$(curl -s http://localhost:9080/zxtm/flipper/firstworking -H "Commkey: $(cat ${ZEUSHOME}/zxtm/conf/commkey)")
a=$(readlink -f ${ZEUSHOME}/zxtm/global.cfg)
thisvTM=${a##*/}
logMsg "020: Checking if this vTM is the cluster leader. firstWorking = ${firstWorking}; thisvTM = ${thisvTM}"

if [[ "$firstWorking" == "$thisvTM" ]]; then
    logMsg "021s vTM is the cluster leader; running the cleanup job."
    # Next, do "garbage collection" on the terminated vTM instances, if any
    #
    # List running instances in our vADC cluster
    logMsg "022: Checking running instances.."
    findTaggedInstances
    cat $jqResFName | sort -rn > $runningInstF
    # Sanity check - we should see ourselves in the $jqResFName
    list=( $(cat $jqResFName | grep "$myInstanceID") )
    if [[ ${#list[*]} == 0 ]]; then
        # LOL WAT
        logMsg "023: Cant't seem to be able to find ourselves running; did you set ClusterID correctly? I have: \"$clusterID\". Bailing."
        exit 1
    fi

    # Go to cluster config dir, and look for instanceIDs in config files there
    logMsg "024: Checking clustered instances.."
    cd $configDir
    grep -i instanceid * | awk '{print $2}' | sort -rn | uniq > $clusteredInstF
    # Compare the two, looking for lines that are present in the cluster config but missing in running list
    logMsg "025: Comparing list of running and clustered instances.."
    diff $clusteredInstF $runningInstF | awk '/^</ { print $2 }' > $deltaInstF

    # Check if our InstanceId is in the list of running
    #
    if [[ -s $deltaInstF ]]; then
        # There is some delta - $deltaInstF isn't empty
        declare -a list
        list=( $(cat $deltaInstF) )
        s_list=$(echo ${list[@]/%/,} | sed -e "s/,$//g")
        logMsg "026: Delta detected - need to do clean up the following instances: $s_list."
        for instId in ${list[@]}; do
            grep -l "$instId" * >> $filesF 2>/dev/null
        done
        if [[ -s $filesF ]]; then
            svIFS=$IFS
            IFS=$(echo -en "\n\b")
            files=( $(cat $filesF) )
            IFS=$svIFS
            for file in "${files[@]}"; do
                logMsg "027: Deleting $file.."
                rm -f "$file"
            done
            logMsg "028: Synchronising cluster state and sleeping to let things settle.."
            # Create signal file. The traffic manager parent deletes this when its
            # finished reading the new config
            touch ${ZEUSHOME}/zxtm/internal/signal
            # Signal the configd and the traffic manager that we've updated the config
            if [[ -s ${ZEUSHOME}/zxtm/internal-configd/pid ]]; then
                kill -HUP $(cat ${ZEUSHOME}/zxtm/internal-configd/pid | awk '{print $1}')
            fi
            if [[ -s ${ZEUSHOME}/zxtm/internal/pid ]]; then
                kill -HUP $(cat ${ZEUSHOME}/zxtm/internal/pid | awk '{print $1}')
            fi
            $configSync
            sleep 30
            logMsg "029: All done, exiting."
        else
            logMsg "030: Hmm, can't find config files with matching instanceIDs; maybe somebody deleted them already. Exiting."
        fi
    else
        logMsg "031: No delta, exiting."
    fi
fi

exit 0
