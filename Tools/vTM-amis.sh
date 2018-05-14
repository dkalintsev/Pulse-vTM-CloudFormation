#!/bin/bash -e
#
# Copyright (c) 2018 Pulse Secure LLC.
#
# Variables
#
# Pattern to match when querying AWS for vTM AMIs
#
vTMAMI='*brocade-virtual-traffic-manager*,*pulse-secure-virtual-traffic-manager*'
#
# Pattern to match the vTM AMI SKU Type; "STM-DEV" by default.
#
SKU='STM-DEV'
#
# You can generate the list of known SKUs by running the following command:
# cat vTM-amis.cache/vTM-amis_*.raw | jq -r '.Images[] | .Name' | \
#     sed -E -e "s/^.*-sku-//g" -e "s/-[0-9a-f]{8}-.*//g" | \
#     sort | uniq
#
# Example of the "Name" string that the above extracts and then edits:
# brocade-virtual-traffic-manager-173-x86_64-sku-SAFPX-CSUB-1000-64-48db060c-ea76-4b49-961d-d9a5172b9451-ami-eb4976fd.4
#
# sed will cut out between "-sku-" and "-48db060c-", returning "SAFPX-CSUB-1000-64"
#
# If you're *not* on MacOS or FreeBSD, please use "-r" instead of "-E" for the
# sed command.
#
# Experiment by feeding SKUs to the script and see if it returns AMIs for fresh versions.
# It seems to be a bit of triald and error, for example:
# ./vTM-amis.sh -s STM-CSUB-1000-H-SAF-64-bw-1gb <= returns fresh AMIs
# ./vTM-amis.sh -s STM-CSUB-1000-H-SAF-64-bw-1gbps <= returns 11.0 and older
# 
#
# There will be many versions available; how many freshest ones to include?
# *Note* this is a hack - there's no way to tell from describe-images output
# if a given Marketplace AMI is actually available, so we just return latest few.
#
Versions='4'
#
# Edit VerList to output specific set of versions. Comment it out to output
# just the latest ${Versions} number of versions found.
# Note: if ${VerList} is specified, it overrides ${Versions}, i.e., if you
# specify say 6 versions in ${VerList} and ${Versions} is set to 4, this
# script will output 6 AMIs, not 4.
#
VerList='104r3 172r2 173 174 181'
#
OPTIND=1
force=0
prof=""
cachedir="vTM-amis.cache"

function show_help {
    printf "This script queries AWS for AMI IDs of Pulse Traffic Manager in all regions,\n"
    printf "and prints the respective \"Parameters\" and \"Mappings\" sections for your\n"
    printf "CloudFormation template.\n\n"
    printf "When run, script checks for existence of per-region cached result files and\n"
    printf "re-uses contents, unless the script was executed with the \"-f\" parameter,\n"
    printf "in which case AWS is re-queried (takes long time).\n\n"
    printf "You can specify which AWS CLI profile to use with the \"-p <profile>\" parameter.\n\n"
    printf "By defualt script outputs AMIs for Dev Edition. Use \"-s <SKU>\" to change that.\n"
    printf "See scipt's cource for the list of available SKUs.\n\n"
    printf "Usage: $0 [-f] [-p <profile>] [-s <SKU>]\n\n"
}

while getopts "h?fp:s:" opt; do
    case "$opt" in
    h|\?)
        show_help
        exit 0
        ;;
    f)  force=1
        ;;
    p)  prof="--profile ${OPTARG}"
        ;;
    s)  SKU="${OPTARG}"
        ;;
    esac
done

shift $((OPTIND-1))

[ "$1" = "--" ] && shift

# We need jq, which should have been installed by now.
which jq >/dev/null 2>&1
if [[ "$?" != "0" ]]; then
    echo "Looks like jq isn't installed; quiting."
    echo "Please install from https://stedolan.github.io/jq/download/"
    exit 1
fi

declare -a regions
declare -a versions

regions=( $(aws $prof --region ap-southeast-2 ec2 describe-regions | jq -r '.Regions[].RegionName') )

if [ ! -d ${cachedir} ]; then
    rm -f ${cachedir}
    mkdir -p ${cachedir}
fi

pos=$(( ${#regions[*]} - 1 ))
for i in $(seq 0 $pos); do
    reg=${regions[$i]}
    printf "Querying region: %s\n" $reg
    fn="${cachedir}/vTM-amis_${reg}_txt"
    if [[ "$force" == "1" ]]; then
        echo "Force parameter was specified; deleting and re-creating \"${fn}.raw\" from AWS."
        rm -f ${fn} ${fn}.raw
    fi
    if [[ -s "${fn}.raw" ]]; then
        echo "Cached contents found for this region; re-run this script as \"$0 -f\" to force update."
        # Regernerating the parsed files from .raw in case we want output for a different SKU
        cat ${fn}.raw | \
            jq -r '.Images[] | .Name + ":" + .ImageId' | \
            grep -- "-${SKU}-" | \
            sed -e "s/ger-/ger:/g" -e "s/-x86/:x86/g" | \
            awk -F ":" '{ printf "%s:%s\n", $2, $4 }' > "$fn"
    else
        aws $prof --region $reg ec2 describe-images --owners aws-marketplace \
            --filters Name=name,Values="$vTMAMI" > ${fn}.raw
        cat ${fn}.raw | \
            jq -r '.Images[] | .Name + ":" + .ImageId' | \
            grep -- "-${SKU}-" | \
            sed -e "s/ger-/ger:/g" -e "s/-x86/:x86/g" | \
            awk -F ":" '{ printf "%s:%s\n", $2, $4 }' > "$fn"
        echo "Got $(wc -l $fn | awk '{print $1}') AMIs"
    fi
done

if [[ "${VerList}" != "" ]]; then
    versions=( $(echo ${VerList}) )
else
    versions=( $(cat ${cachedir}/vTM-amis_*_txt | awk -F: '{print $1}' | sort -n | uniq | tail -"$Versions") )
fi
pos1=$(( ${#versions[*]} - 1 ))

printf "\n\nCut and paste the output below into your CloudFormation template:\n"
printf "=================================================================\n\n"

printf "  \"Parameters\" : {\n"
printf "    \"vTMVers\" : {\n"
printf "      \"Description\" : \"Please select vTM version:\",\n"
printf "      \"Type\" : \"String\",\n"
printf "      \"Default\" : \"%s\",\n" ${versions[$pos1]}
printf "      \"AllowedValues\" : [\n"
for j in $(seq 0 $pos1); do
    printf "        \"%s\"" ${versions[$j]}
    if (( $j < $pos1 )); then
        printf ",\n"
    else
        printf "\n"
    fi
done
printf "      ],\n"
printf "      \"ConstraintDescription\" : \"Must be a valid vTM version\"\n"
printf "    }\n"
printf "  }\n\n"

printf "  \"Mappings\" : {\n"
printf "    \"vTMAMI\" : {\n"
for i in $(seq 0 $pos); do
    reg=${regions[$i]}
    fn="${cachedir}/vTM-amis_${reg}_txt"
    if [[ -s "$fn" ]]; then
        printf "      \"%s\" : {" $reg
        for j in $(seq 0 $pos1); do
            ver=${versions[$j]}
            ami=$(egrep "^$ver:" "$fn" | cut -f2 -d:)
            if [[ ! -z "$ami" ]]; then
                printf " \"%s\" : \"%s\"" $ver $ami
                if (( $j < $pos1 )); then
                    printf ","
                fi
            fi
        done
        if (( $i == $pos )); then
            printf " }\n"
        else
            printf " },\n"
        fi
    fi
done
printf "    }\n"
printf "  }\n"
printf "\n=================================================================\n\n"
