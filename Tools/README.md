# vTM-amis

A shell script to fetch a list of AMIs from AWS and build "Versions" parameter and "AMI" map for the Pulse vTM CloudFormation template.

Caveats:

- This script will also return AMIs for versions that are "no longer available" on Marketplace. I couldn't see any difference between what an "available" and "no longer available" AMI looks like in "aws ec2 describe-images" output. If you know how I can tell between them, please let me know.
- Version numbers look a bit ugly without dots, e.g., Version "17.2" is listed as "172". I really wanted to make it look proper, but again couldn't find a way around CloudFormation's limitation on key names in "Mappings" maps. It only allows alphanumerics. :(

Script does the following:
- Query list of AWS regions.
- Go through the list of regions, and check if there's a cache file for a region from old run.
- If there's a file, contents are used to produce output.
- If there's no file for one or more regions, query AWS for the AMIs, and cache results
- Once done with cache files, process them and produce the results.

There are a couple parameters you can change that are located at the start of the script - one that defines the AMI string to use to look up the AMIs, and another how many versions to generate the output for. If you change the first one, you'll need to regenerate the cache, by re-running the script with the `-f` parameter. If you change the second one, your existing cache files, if any, are good - just re-run the script to generate the amended output.

Script accepts `-h|-?` for help, `-p` to specify profile from your `~/.aws/credentials` file, `-f` to force re-creation of all cache files, and `-s` to specify the SKU. Please see the script source for how to find the available SKUs.

If you need to re-build cache for particular region, just delete the cache file for that region. It should be fairly self-evident what region each cache file corresponds to.

Here's an example of a run:

```
$ ./vTM-amis.sh -p myprofile
Querying region: ap-south-1
Got 8 AMIs
Querying region: eu-west-2
Got 6 AMIs
Querying region: eu-west-1
Got 31 AMIs
Querying region: ap-northeast-2
Got 11 AMIs
Querying region: ap-northeast-1
Got 31 AMIs
Querying region: sa-east-1
Got 28 AMIs
Querying region: ca-central-1
Got 6 AMIs
Querying region: ap-southeast-1
Got 31 AMIs
Querying region: ap-southeast-2
Got 28 AMIs
Querying region: eu-central-1
Got 16 AMIs
Querying region: us-east-1
Got 31 AMIs
Querying region: us-east-2
Got 6 AMIs
Querying region: us-west-1
Got 31 AMIs
Querying region: us-west-2
Got 31 AMIs


Cut and paste the output below into your CloudFormation template:
=================================================================

  "Parameters" : {
    "vTMVers" : {
      "Description" : "Please select vTM version:",
      "Type" : "String",
      "Default" : "173",
      "AllowedValues" : [
        "111",
        "171",
        "172",
        "173"
      ],
      "ConstraintDescription" : "Must be a valid vTM version"
    }
  }

  "Mappings" : {
    "vTMAMI" : {
      "ap-south-1" : { "111" : "ami-856115ea", "171" : "ami-b73f4ed8", "172" : "ami-34512e5b", "173" : "ami-8fc9b7e0" },
      "eu-west-2" : { "111" : "ami-60212b04", "171" : "ami-72a1ab16", "172" : "ami-2baeb94f", "173" : "ami-bccfd9d8" },
      "eu-west-1" : { "111" : "ami-3bd89748", "171" : "ami-04f7a862", "172" : "ami-121c0374", "173" : "ami-352fce4c" },
      "ap-northeast-2" : { "111" : "ami-5ffb2f31", "171" : "ami-17e83979", "172" : "ami-d89946b6", "173" : "ami-9fbf61f1" },
      "ap-northeast-1" : { "111" : "ami-381dba59", "171" : "ami-1a7e047d", "172" : "ami-a7676ec0", "173" : "ami-f61e0191" },
      "sa-east-1" : { "111" : "ami-a362ffcf", "171" : "ami-b686e3da", "172" : "ami-d1cda5bd", "173" : "ami-0b7f0a67" },
      "ca-central-1" : { "111" : "ami-ea84368e", "171" : "ami-52d56836", "172" : "ami-5cf24d38", "173" : "ami-ec7ac588" },
      "ap-southeast-1" : { "111" : "ami-ab4fe9c8", "171" : "ami-76e05515", "172" : "ami-9ce765ff", "173" : "ami-1abb3179" },
      "ap-southeast-2" : { "111" : "ami-5a5e6339", "171" : "ami-74303717", "172" : "ami-8e6677ed", "173" : "ami-a1ccdec2" },
      "eu-central-1" : { "111" : "ami-9e30c9f1", "171" : "ami-6ba36d04", "172" : "ami-1861c577", "173" : "ami-d66fcfb9" },
      "us-east-1" : { "111" : "ami-a87626bf", "171" : "ami-ca0effdc", "172" : "ami-74d9fd62", "173" : "ami-268c8930" },
      "us-east-2" : { "111" : "ami-e03a6085", "171" : "ami-9f5a7ffa", "172" : "ami-fca18799", "173" : "ami-d4e2c3b1" },
      "us-west-1" : { "111" : "ami-dbfdb5bb", "171" : "ami-86d082e6", "172" : "ami-c2b597a2", "173" : "ami-6be4cb0b" },
      "us-west-2" : { "111" : "ami-d12c89b1", "171" : "ami-38f04958", "172" : "ami-56ebe32f", "173" : "ami-5e2b3827" }
    }
  }

=================================================================
```

Help:

```
$ ./vTM-amis.sh -h
This script queries AWS for AMI IDs of Pulse Traffic Manager in all regions,
and prints the respective "Parameters" and "Mappings" sections for your
CloudFormation template.

When run, script checks for existence of per-region cached result files and
re-uses contents, unless the script was executed with the "-f" parameter,
in which case AWS is re-queried (takes long time).

You can specify which AWS CLI profile to use with the "-p <profile>" parameter.

By defualt script outputs AMIs for Dev Edition. Use "-s <SKU>" to change that.
See scipt's cource for the list of available SKUs.

Usage: ./vTM-amis.sh [-f] [-p <profile>] [-s <SKU>]

```

