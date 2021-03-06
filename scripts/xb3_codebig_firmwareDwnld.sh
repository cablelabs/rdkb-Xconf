#!/bin/sh
##########################################################################
# If not stated otherwise in this file or this component's Licenses.txt
# file the following copyright and licenses apply:
#
# Copyright 2017 RDK Management
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
##########################################################################
source /etc/utopia/service.d/log_capture_path.sh
source /fss/gw/etc/utopia/service.d/log_env_var.sh
source /lib/rdk/getpartnerid.sh

if [ -f /etc/device.properties ]
then
    source /etc/device.properties
fi

XCONF_LOG_FILE_NAME=xconf.txt.0
XCONF_LOG_FILE_PATHNAME=${LOG_PATH}/${XCONF_LOG_FILE_NAME}
XCONF_LOG_FILE=${XCONF_LOG_FILE_PATHNAME}

CURL_PATH=/fss/gw/usr/bin
interface=erouter0
BIN_PATH=/fss/gw/usr/bin
REBOOT_WAIT="/tmp/.waitingreboot"
DOWNLOAD_INPROGRESS="/tmp/.downloadingfw"
deferReboot="/tmp/.deferringreboot"
NO_DOWNLOAD="/tmp/.downloadBreak"
ABORT_REBOOT="/tmp/AbortReboot"
abortReboot_count=0

#GLOBAL DECLARATIONS
image_upg_avl=0
reb_window=0
CDL_SERVER_OVERRIDE=0
FILENAME="/tmp/response.txt"
OUTPUT="/tmp/XconfOutput.txt"
HTTP_CODE=/tmp/fwdl_http_code.txt
WAN_INTERFACE="erouter0"

firmwareName_configured=""

isPeriodicFWCheckEnabled=`syscfg get PeriodicFWCheck_Enable`

#if [ $# -ne 1 ]; then
        #echo "USAGE: $0 <TFTP Server IP> <UploadProtocol> <UploadHttpLink> <uploadOnReboot>"
#    echo_t "USAGE: $0 <firmwareName>"
#else
#       firmwareName_configured=$1
#fi

#
# release numbering system rules
#

# 5 part release numbering scheme where the five parts consisted of
#+ "Major Rev"."Minor Rev"."Internal Rev". "Patch Level"."SPIN".

# 1.Major  Rev and Minor Rev will follow the matching RDKB version.
# 2.Any field which formerly contained  a zero (except for "Minor Rev") will be suppressed in the build number as well as the preceding "."
# 3.The "Spin" field will be  preceded by  "s"  for spin,  rather than a ".'  ie s4
# 4.The Spin field is always in the range of 1-x; Since it is  never 0, this field is always present.
# 5.The "Patch Level" field will be preceded by  "p" (lower case)  for patch rather than a "." . ie p2
# 6.The patch level field is in the range of 0-x.  If the patch level value is zero, the entire field will be suppressed including the leading "p".
# 7."Internal Rev" can be in the range of 0-x, When the value of Internal Rev is 0, it will be suppressed, including the preceding "."
# 8.Initial State: We will be reverting the Internal Rev to Zero. This will allow us to suppress the field initially
# 9. The "Patch level" filed if present will always preceed "Spin" field.

# example build release numbers
# 1.22s55555                    spin_on_minor           3
# 1.22p4444s55555               spin_on_patch           1
# 1.22.333s55555                spin_on_internal        2
# 1.22.333p4444s55555           spin_on_patch           3
#

# param1 : cur_rel_num param2 : upg_rel_num
# assumption :
#       cur and upg firmware version are validated against release numbering system rules
#       no assumption is made about the length of the fields
# spin_on : 1 spin_on_patch 2 spin_on_internal 3 spin_on_minor

checkFirmwareUpgCriteria()
{
    image_upg_avl=0;

    # Retrieve current firmware version
        currentVersion=`dmcli eRT getvalues Device.DeviceInfo.X_CISCO_COM_FirmwareName | grep DPC3941 | cut -d ":" -f 3 | tr -d ' ' `

    echo_t "XCONF SCRIPT : CurrentVersion : $currentVersion"
    echo_t "XCONF SCRIPT : UpgradeVersion : $firmwareVersion"

    echo_t "XCONF SCRIPT : CurrentVersion : $currentVersion" >> $XCONF_LOG_FILE
    echo_t "XCONF SCRIPT : UpgradeVersion : $firmwareVersion" >> $XCONF_LOG_FILE

    cur_rel_num=`echo $currentVersion | cut -d "_" -f 2`
    upg_rel_num=`echo $firmwareVersion | cut -d "_" -f 2`

    cur_major_rev=0
    cur_minor_rev=0
    cur_internal_rev=0
    cur_patch_level=0
    cur_spin=1
    cur_spin_on=0

    upg_major_rev=0
    upg_minor_rev=0
    upg_internal_rev=0
    upg_patch_level=0
    upg_spin=1
    upg_spin_on=0

    #
    # Parse and normalize current firmware version
    #

    # major
    cur_major_rev=`echo $cur_rel_num | cut -d "." -f 1`

    # minor
    cur_first_dot_length=`expr match "${cur_rel_num}" '[0-9]*\.'`
    cur_second_dot_or_p_or_s_length=`expr match "${cur_rel_num}" '[0-9]*\.[0-9]*[\.,p,s]'`
    length=${cur_second_dot_or_p_or_s_length}
    length=$((length-$cur_first_dot_length))
    length=$((length-1))
    cur_minor_rev=${cur_rel_num:$cur_first_dot_length:$length}

    # internal
    cur_second_dot_length=`expr match "${cur_rel_num}" '[0-9]*\.[0-9]*[\.]'`
    #echo "XCONF SCRIPT : cur_second_dot_length=$cur_second_dot_length"
    if [ $cur_second_dot_length -eq 0 ]; then
        cur_internal_rev=0
    else
        cur_p_or_s_length=`expr match "${cur_rel_num}" '[0-9]*\.[0-9]*\.[0-9]*[p,s]'`
        #echo "XCONF SCRIPT : cur_p_or_s_length=$cur_p_or_s_length"
        length=${cur_p_or_s_length}
        length=$((length-$cur_second_dot_length))
        length=$((length-1))
        cur_internal_rev=${cur_rel_num:$cur_second_dot_length:$length}
    fi

    # patch
    cur_s_npos=`expr index "${cur_rel_num}" s`
    cur_p_npos=`expr index "${cur_rel_num}" p`
    if [ $cur_p_npos -eq 0 ]; then
        cur_patch_level=0
    else
        length=${cur_s_npos}
        length=$((length-$cur_p_npos))
        length=$((length-1))
        cur_patch_level=${cur_rel_num:$cur_p_npos:$length}
    fi

    # spin
    length=${cur_s_npos}
    cur_spin=${cur_rel_num:$length}

    if [ $cur_patch_level -ne 0 ];then
        cur_spin_on=1;
    elif [ $cur_internal_rev -ne 0 ];then
        cur_spin_on=2;
    else
        cur_spin_on=3;
    fi

    #
    # Parse and normalize upgrade firmware version
    #

    # major
    upg_major_rev=`echo $upg_rel_num | cut -d "." -f 1`

    # minor
    upg_first_dot_length=`expr match "${upg_rel_num}" '[0-9]*\.'`
    upg_second_dot_or_p_or_s_length=`expr match "${upg_rel_num}" '[0-9]*\.[0-9]*[\.,p,s]'`
    length=${upg_second_dot_or_p_or_s_length}
    length=$((length-$upg_first_dot_length))
    length=$((length-1))
    upg_minor_rev=${upg_rel_num:$upg_first_dot_length:$length}

    # internal
    upg_second_dot_length=`expr match "${upg_rel_num}" '[0-9]*\.[0-9]*[\.]'`
    #echo "XCONF SCRIPT : upg_second_dot_length=$upg_second_dot_length"
    if [ $upg_second_dot_length -eq 0 ]; then
        upg_internal_rev=0
    else
        upg_p_or_s_length=`expr match "${upg_rel_num}" '[0-9]*\.[0-9]*\.[0-9]*[p,s]'`
        #echo "XCONF SCRIPT : upg_p_or_s_length=$upg_p_or_s_length"
        length=${upg_p_or_s_length}
        length=$((length-$upg_second_dot_length))
        length=$((length-1))
        upg_internal_rev=${upg_rel_num:$upg_second_dot_length:$length}
    fi

    # patch
    upg_s_npos=`expr index "${upg_rel_num}" s`
    upg_p_npos=`expr index "${upg_rel_num}" p`
    if [ $upg_p_npos -eq 0 ]; then
        upg_patch_level=0
    else
        length=${upg_s_npos}
        length=$((length-$upg_p_npos))
        length=$((length-1))
        upg_patch_level=${upg_rel_num:$upg_p_npos:$length}
    fi

    # spin
    length=${upg_s_npos}
    upg_spin=${upg_rel_num:$length}

    if [ $upg_patch_level -ne 0 ];then
        upg_spin_on=1;
    elif [ $upg_internal_rev -ne 0 ];then
        upg_spin_on=2;
    else
        upg_spin_on=3;
    fi

        if [ $upg_major_rev -gt $cur_major_rev ];then
            image_upg_avl=1;

        elif [ $upg_major_rev -lt $cur_major_rev ];then
            image_upg_avl=1

        elif [ $upg_major_rev -eq $cur_major_rev ];then
            echo_t "XCONF SCRIPT : Current and upgrade firmware major versions equal,"

            if [ $upg_minor_rev -gt $cur_minor_rev ];then
                image_upg_avl=1

            elif [ $upg_minor_rev -lt $cur_minor_rev ];then
                image_upg_avl=1

            elif [ $upg_minor_rev -eq $cur_minor_rev ];then
                echo_t "XCONF SCRIPT : Current and upgrade minor versions equal"

                if [ $upg_internal_rev -gt $cur_internal_rev ];then
                    image_upg_avl=1;

                elif [ $upg_internal_rev -lt $cur_internal_rev ];then
                    image_upg_avl=1

                elif [ $upg_internal_rev -eq $cur_internal_rev ];then
                    echo_t "XCONF SCRIPT : Current and upgrade firmware internal versions equal,"

                    if [ $upg_patch_level -gt $cur_patch_level ];then
                        image_upg_avl=1;

                    elif [ $upg_patch_level -lt $cur_patch_level ];then
                        image_upg_avl=1

                    elif [ $upg_patch_level -eq $cur_patch_level ];then
                        echo_t "XCONF SCRIPT : Current and upgrade firmware patch versions equal,"

                        if [ $upg_spin -gt $cur_spin ];then
                            image_upg_avl=1

                        elif [ $upg_spin -lt $cur_spin ];then
                            image_upg_avl=1

                        elif [ $upg_spin -eq $cur_spin ];then
                            echo_t "XCONF SCRIPT : Current and upgrade  spin versions equal/less"
                            image_upg_avl=0
                        fi
                    fi
                fi
            fi
        fi

    echo_t "XCONF SCRIPT : current --> [$cur_major_rev , $cur_minor_rev , $cur_internal_rev , $cur_patch_level , $cur_spin , $cur_spin_on , $cur_p_npos , $cur_s_npos]"
    echo_t "XCONF SCRIPT : current --> [$cur_major_rev , $cur_minor_rev , $cur_internal_rev , $cur_patch_level , $cur_spin , $cur_spin_on , $cur_p_npos , $cur_s_npos]" >> $XCONF_LOG_FILE

    echo_t "XCONF SCRIPT : upgrade --> [$upg_major_rev , $upg_minor_rev , $upg_internal_rev , $upg_patch_level , $upg_spin , $upg_spin_on , $upg_p_npos , $upg_s_npos]"
    echo_t "XCONF SCRIPT : upgrade --> [$upg_major_rev , $upg_minor_rev , $upg_internal_rev , $upg_patch_level , $upg_spin , $upg_spin_on , $upg_p_npos , $upg_s_npos]" >> $XCONF_LOG_FILE

    echo_t "XCONF SCRIPT : [$image_upg_avl] $cur_rel_num --> $upg_rel_num"
    echo_t "XCONF SCRIPT : [$image_upg_avl] $cur_rel_num --> $upg_rel_num" >> $XCONF_LOG_FILE

}

#This is a temporary function added to check FirmwareUpgCriteria
#This function will not check any other criteria other than matching current firmware and requested firmware

checkFirmwareUpgCriteria_temp()
{
                image_upg_avl=0

                currentVersion=`cat /version.txt | grep "imagename:" | cut -d ":" -f 2`
                firmwareVersion=`grep firmwareVersion $OUTPUT | cut -d \| -f2 | sed 's/-signed.*//'`
                currentVersion=`echo $currentVersion | tr '[A-Z]' '[a-z]'`
                firmwareVersion=`echo $firmwareVersion | tr '[A-Z]' '[a-z]'`
                if [ "$currentVersion" != "" ] && [ "$firmwareVersion" != "" ];then
                        if [ "$currentVersion" == "$firmwareVersion" ]; then
                                echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are same. No upgrade/downgrade required"
                                echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are same. No upgrade/downgrade required">> $XCONF_LOG_FILE
                                image_upg_avl=0
				if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
		  		   exit
		        	fi
                        else
                                echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are different. Processing Upgrade/Downgrade"
                                echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are different. Processing Upgrade/Downgrade">> $XCONF_LOG_FILE
                                image_upg_avl=1
                        fi
                else
                        echo_t "XCONF SCRIPT : Current image ("$currentVersion") Or Requested image ("$firmwareVersion") returned NULL. No Upgrade/Downgrade"
                        echo_t "XCONF SCRIPT : Current image ("$currentVersion") Or Requested image ("$firmwareVersion") returned NULL. No Upgrade/Downgrade">> $XCONF_LOG_FILE
                        image_upg_avl=0
			if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
                                   exit  
                        fi  
                                                                                                                                                                       fi
}

getRequestType()
{
     request_type=2
     if [ "$1" == "ci.xconfds.ccp.xcal.tv" ]; then
            request_type=4
     fi
     return $request_type
}

# Adjusting date. This is required for liboauth patch
adjustDate()
{
retries=0
while [ "$retries" -lt 10 ]
do
    echo_t "Trial $retries..."

    if [ $retries -ne 0 ]
    then
        if [ -f /nvram/adjdate.txt ];
        then
        	echo -e "$0  --> /nvram/adjdate exist. It is used by another program"
            echo -e "$0 --> Sleeping 15 seconds and try again\n"
        else
            echo -e "$0  --> /nvram/adjdate NOT exist. Writing date value"
            dateString=`date +'%s'`
            count=$(expr $dateString - $SECONDV)
            echo "$0  --> date adjusted:"
            date -d @$count
            echo $count > /nvram/adjdate.txt
            break
         fi
    fi

        retries=`expr $retries + 1`
        sleep 15
done
if [ ! -f /nvram/adjdate.txt ];then
        echo_t "XCONF Failed...... Because unable to write to /nvram/adjdate.txt"
fi

}


# Check if a new image is available on the XCONF server
getFirmwareUpgDetail()
{
    # The retry count and flag are used to resend a
    # query to the XCONF server if issues with the
    # respose or the URL received
    xconf_retry_count=1
    retry_flag=1
    isIPv6=`ifconfig erouter0 | grep inet6 | grep -i 'Global'`

    # Set the XCONF server url read from /tmp/Xconf
    # Determine the env from $type

    #s16 : env=`cat /tmp/Xconf | cut -d "=" -f1`
    env=$type
    xconf_url=`cat /tmp/Xconf | cut -d "=" -f2`

    # If an /tmp/Xconf file was not created, use the default values
    if [ ! -f /tmp/Xconf ]; then
        echo_t "XCONF SCRIPT : ERROR : /tmp/Xconf file not found! Using defaults"
        echo_t "XCONF SCRIPT : ERROR : /tmp/Xconf file not found! Using defaults" >> $XCONF_LOG_FILE
        env="PROD"
        xconf_url="https://xconf.xcal.tv/xconf/swu/stb/"
    fi

    # if xconf_url uses http, then log it
    if [ `echo "${xconf_url:0:6}" | tr '[:upper:]' '[:lower:]'` != "https:" ]; then
        echo "firmware download using insecure protocol to $xconf_url" >> $XCONF_LOG_FILE
    fi

    echo_t "XCONF SCRIPT : env is $env"
    echo_t "XCONF SCRIPT : xconf url  is $xconf_url"

    # If interface doesnt have ipv6 address then we will force the curl to go with ipv4.
    # Otherwise we will not specify the ip address family in curl options
    if [ "$isIPv6" != "" ]; then
        addr_type=""
    else
        addr_type="-4"
    fi

    # Check with the XCONF server if an update is available
    while [ $xconf_retry_count -le 3 ] && [ $retry_flag -eq 1 ]
    do

        echo_t "**RETRY is $xconf_retry_count and RETRY_FLAG is $retry_flag**" >> $XCONF_LOG_FILE

        # White list the Xconf server url
        #echo "XCONF SCRIPT : Whitelisting Xconf Server url : $xconf_url"
        #echo "XCONF SCRIPT : Whitelisting Xconf Server url : $xconf_url" >> $XCONF_LOG_FILE
        #/etc/whitelist.sh "$xconf_url"

        # Perform cleanup by deleting any previous responses
        rm -f $FILENAME
        rm -f $HTTP_CODE
        rm -f $OUTPUT

            firmwareDownloadProtocol=""
            firmwareFilename=""
            firmwareLocation=""
            firmwareVersion=""
            rebootImmediately=""
        ipv6FirmwareLocation=""
        upgradeDelay=""

                currentVersion=`cat /version.txt | grep "imagename:" | cut -d ":" -f 2`
                devicemodel=`dmcli eRT getv Device.DeviceInfo.ModelName | grep DPC3941 | cut -d ":" -f 3 | tr -d ' ' `
        MAC=`ifconfig  | grep $interface |  grep -v $interface:0 | tr -s ' ' | cut -d ' ' -f5`
                date=`date`

        echo_t "XCONF SCRIPT : CURRENT VERSION : $currentVersion"
        echo_t "XCONF SCRIPT : CURRENT MAC  : $MAC"
        echo_t "XCONF SCRIPT : CURRENT DATE : $date"
        if [ $CDL_SERVER_OVERRIDE -eq 0 ];then
            SECONDV=`dmcli eRT getv Device.X_CISCO_COM_CableModem.TimeOffset | grep value | cut -d ":" -f 3 | tr -d ' ' `
            serial=`dmcli eRT getv Device.DeviceInfo.SerialNumber | grep value | cut -d ":" -f 3 | tr -d ' ' `
            CB_CAPABILITIES='&capabilities=rebootDecoupled&capabilities="RCDL"&capabilities="supportsFullHttpUrl"'
            request_type=2

                echo_t "XCONF SCRIPT : OFFSET TIME : $SECONDV" >> $XCONF_LOG_FIL
                echo_t "XCONF SCRIPT : SERIAL : $serial" >> $XCONF_LOG_FILE

        echo_t "XCONF SCRIPT : Adjusting date"

	adjustDate                
		fi

		if [ "$firmwareName_configured" != "" ]; then
                    currentVersion=$firmwareName_configured
                fi
                partnerId=$(getPartnerId)
		if [ $CDL_SERVER_OVERRIDE -eq 1 ];then
                        echo_t "Trying Direct Communication" >> $XCONF_LOG_FILE
			echo_t "XCONF SCRIPT : Post string creation"
			POSTSTR="eStbMac=$MAC&firmwareVersion=$currentVersion&env=$env&model=$devicemodel&partnerId=$partnerId&localtime=$date&timezone=EST05&capabilities=\"rebootDecoupled\"&capabilities=\"RCDL\"&capabilities=\"supportsFullHttpUrl\""
			echo_t "XCONF SCRIPT : POSTSTR : $POSTSTR" >> $XCONF_LOG_FILE

			# Query the  XCONF Server, using TLS 1.2
			echo_t "Attempting TLS1.2 connection to $xconf_url " >> $XCONF_LOG_FILE
			CURL_CMD="curl --connect-timeout 30 --interface $interface $addr_type -w '%{http_code}\n' --tlsv1.2 -d \"$POSTSTR\" -o \"$FILENAME\" $xconf_url -m 30"
			echo_t "CURL_CMD: $CURL_CMD" >> $XCONF_LOG_FILE
			result= eval "$CURL_CMD" > $HTTP_CODE
			ret=$?

			HTTP_RESPONSE_CODE=$(awk -F\" '{print $1}' $HTTP_CODE)
			echo_t "ret = $ret http_code: $HTTP_RESPONSE_CODE" >> $XCONF_LOG_FILE

		else
                echo_t "Trying Codebig Communication" >> $XCONF_LOG_FILE
                ###############Jason string creation##########
                echo_t "XCONF SCRIPT : Jason string creation"
                 
                JSONSTR="&eStbMac=${MAC}&firmwareVersion=${currentVersion}&env=${env}&model=${devicemodel}&partnerId=${partnerId}&serial=$serial&localtime=${date}&timezone=US/Eastern${CB_CAPABILITIES}"
                echo_t "XCONF SCRIPT : JSONSTR : $JSONSTR" >> $XCONF_LOG_FILE
                echo_t "XCONF SCRIPT : Get Signed URL from configparamgen"

                domain_name=`echo $xconf_url | cut -d / -f3`
                getRequestType $domain_name
                request_type=$?

                ########Get Signed URL from configparamgen.################
                SIGN_CMD="configparamgen $request_type \"$JSONSTR\""
                eval $SIGN_CMD > /nvram/.signedRequest
                echo_t "configparamgen success" >> $XCONF_LOG_FILE
                CB_SIGNED_REQUEST=`cat /nvram/.signedRequest`
                echo_t "CB_SIGNED_REQUEST : $CB_SIGNED_REQUEST" >>$XCONF_LOG_FILE
                rm -f /nvram/.signedRequest
                rm -f /nvram/adjdate.txt

                echo_t "XCONF SCRIPT : Executing CURL for  https://xconf-prod.codebig2.net "

            # Query the  XCONF Server, using TLS 1.2
            echo_t "Attempting TLS1.2 connection to $xconf_url " >> $XCONF_LOG_FILE
            CURL_CMD="curl --connect-timeout 30 --interface $interface $addr_type -w '%{http_code}\n' --tlsv1.2 -o \"$FILENAME\" \"$CB_SIGNED_REQUEST\" -m 30"
            echo_t "CURL_CMD:$CURL_CMD"
            echo_t "CURL_CMD:$CURL_CMD" >> $XCONF_LOG_FILE
            result= eval "$CURL_CMD" > $HTTP_CODE
            ret=$?

            HTTP_RESPONSE_CODE=$(awk -F\" '{print $1}' $HTTP_CODE)
            echo_t "ret = $ret http_code: $HTTP_RESPONSE_CODE" >> $XCONF_LOG_FILE
            echo_t "Codebig Communication - ret:$ret, http_code:$HTTP_RESPONSE_CODE" >> $XCONF_LOG_FILE
		fi	

        echo_t "XCONF SCRIPT : HTTP RESPONSE CODE is $HTTP_RESPONSE_CODE"
        echo_t "XCONF SCRIPT : HTTP RESPONSE CODE is $HTTP_RESPONSE_CODE" >> $XCONF_LOG_FILE

            if [ $HTTP_RESPONSE_CODE -eq 200 ];then
		    # Print the response
		    cat $FILENAME
		    echo
		    cat "$FILENAME" >> $XCONF_LOG_FILE
		    echo >> $XCONF_LOG_FILE

                    cat "$FILENAME" | tr -d '\n' | sed 's/[{}]//g' | awk  '{n=split($0,a,","); for (i=1; i<=n; i++) print a[i]}' | sed 's/\"\:\"/\|/g' | sed -r 's/\"\:(true)($)/\|true/gI' | sed -r 's/\"\:(false)($)/\|false/gI' | sed -r 's/\"\:(null)($)/\|\1/gI' | sed -r 's/\"\:([0-9]+)($)/\|\1/g' | sed 's/[\,]/ /g' | sed 's/\"//g' > $OUTPUT

                    retry_flag=0

		firmwareDownloadProtocol=`grep firmwareDownloadProtocol $OUTPUT  | cut -d \| -f2`

                echo_t "XCONF SCRIPT : firmwareDownloadProtocol [$firmwareDownloadProtocol]"
                echo_t "XCONF SCRIPT : firmwareDownloadProtocol [$firmwareDownloadProtocol]" >> $XCONF_LOG_FILE

                    if [ "$firmwareDownloadProtocol" == "http" ];then
                echo_t "XCONF SCRIPT : Download image from HTTP server" >> $XCONF_LOG_FILE

		firmwareLocation=`grep firmwareLocation $OUTPUT | cut -d \| -f2 | tr -d ' '`
            else
                echo_t "XCONF SCRIPT : Download from $firmwareDownloadProtocol server not supported, check XCONF server configurations"
                echo_t "XCONF SCRIPT : Download from $firmwareDownloadProtocol server not supported, check XCONF server configurations" >> $XCONF_LOG_FILE
                echo_t "XCONF SCRIPT : Retrying query in 2 minutes" >> $XCONF_LOG_FILE

                # sleep for 2 minutes and retry
                sleep 120;

                retry_flag=1
                image_upg_avl=0

                #Increment the retry count
                xconf_retry_count=$((xconf_retry_count+1))

                continue
            fi
            echo "$firmwareLocation" > /tmp/.xconfssrdownloadurl
            firmwareFilename=`grep firmwareFilename $OUTPUT | cut -d \| -f2`
            firmwareVersion=`grep firmwareVersion $OUTPUT | cut -d \| -f2 | sed 's/-signed.*//'`
            ipv6FirmwareLocation=`grep ipv6FirmwareLocation  $OUTPUT | cut -d \| -f2 | tr -d ' '`
            upgradeDelay=`grep upgradeDelay $OUTPUT | cut -d \| -f2`

		rebootImmediately=`grep rebootImmediately $OUTPUT | cut -d \| -f2`

                 echo_t "XCONF SCRIPT : Protocol :"$firmwareDownloadProtocol
                 echo_t "XCONF SCRIPT : Filename :"$firmwareFilename
                 echo_t "XCONF SCRIPT : Location :"$firmwareLocation
                 echo_t "XCONF SCRIPT : Version  :"$firmwareVersion
                 echo_t "XCONF SCRIPT : Reboot   :"$rebootImmediately

                        if [ "X"$firmwareLocation = "X" ];then
                echo_t "XCONF SCRIPT : No URL received in $FILENAME" >> $XCONF_LOG_FILE
                retry_flag=1
                image_upg_avl=0

                #Increment the retry count
                xconf_retry_count=$((xconf_retry_count+1))

            else
				if [ $CDL_SERVER_OVERRIDE -eq 0 ];then

                        imageHTTPURL="$firmwareLocation/$firmwareFilename"
                        domainName=`echo $imageHTTPURL | awk -F/ '{print $3}'`
                        imageHTTPURL=`echo $imageHTTPURL | sed -e "s|.*$domainName||g"`

                        echo imageHTTPURL : $imageHTTPURL
                        echo $imageHTTPURL >> $XCONF_LOG_FILE
			
						adjustDate

                        echo_t "XCONF SCRIPT : Get Signed URL from configparamgen for ssr respose"

                        ########Get Signed URL from configparamgen.################
                        SIGN_CMD="configparamgen 1 \"$imageHTTPURL\""
                        echo $SIGN_CMD >>$XCONF_LOG_FILE
                        echo -e "\n"
                        eval $SIGN_CMD > /nvram/.signedRequest
                        cbSignedimageHTTPURL1=`cat /nvram/.signedRequest`

                        echo cbSignedimageHTTPURL1 : $cbSignedimageHTTPURL1
                        echo $cbSignedimageHTTPURL1 >>$XCONF_LOG_FILE
                        rm -f /nvram/.signedRequest
                        rm -f /nvram/adjdate.txt

                        cbSignedimageHTTPURL=`echo $cbSignedimageHTTPURL1 | sed 's|stb_cdl%2F|stb_cdl/|g'`
                        serverUrl=`echo $cbSignedimageHTTPURL | sed -e "s|&oauth_consumer_key.*||g"`
                        authorizationHeader=`echo $cbSignedimageHTTPURL | sed -e "s|&|\", |g" -e "s|=|=\"|g" -e "s|.*oauth_consumer_key|oauth_consumer_key|g"`
                        authorizationHeader="Authorization: OAuth realm=\"\", $authorizationHeader\""

                        echo $authorizationHeader > /tmp/authHeader
                        echo_t "authorizationHeader written to /tmp/authHeader"

                   CURL_CMD="curl --connect-timeout 30 --tlsv1.2 --interface $interface -H '$authorizationHeader' $addr_type -w '%{http_code}\n' -fgLo /var/$firmwareFilename '$serverUrl'"
                        echo CURL_CMD_CDL : $CURL_CMD
                        echo CURL_CMD_CDL : $CURL_CMD >>$XCONF_LOG_FILE
                    echo_t "Execute above curl command to start code download (if you want to try manually)"
				fi	

                # Check if a newer version was returned in the response
            # If image_upg_avl = 0, retry reconnecting with XCONf in next window
            # If image_upg_avl = 1, download new firmware
                        #This is a temporary function added to check FirmwareUpgCriteria
                        #This function will not check any other criteria other than matching current firmware and requested firmware

                        checkFirmwareUpgCriteria_temp
                        fi


        # If a response code of 404 was received, exit
            elif [ $HTTP_RESPONSE_CODE -eq 404 ]; then
                retry_flag=0
                image_upg_avl=0
                echo "XCONF SCRIPT : Response code received is 404" >> $XCONF_LOG_FILE
                if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
		   exit
		fi
        # If a response code of 0 was received, the server is unreachable
        # Try reconnecting
        else
            echo_t "XCONF SCRIPT : Response code is $HTTP_RESPONSE_CODE, sleeping for 2 minutes and retrying" >> $XCONF_LOG_FILE
            # sleep for 2 minutes and retry
            sleep 120;

            retry_flag=1
            image_upg_avl=0

                #Increment the retry count
             xconf_retry_count=$((xconf_retry_count+1))

       fi

    done

    if [ $xconf_retry_count -eq 4 ] && [ $image_upg_avl -eq 0 ];then
        echo_t "XCONF SCRIPT : Retry limit to connect with XCONF server reached"
        if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
	   exit
	fi
    fi
}

calcRandTime()
{
    rand_hr=0
    rand_min=0
    rand_sec=0

    # Calculate random min
    rand_min=`awk -v min=0 -v max=59 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

    # Calculate random second
    rand_sec=`awk -v min=0 -v max=59 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

    # Extract maintenance window start and end time
    start_time=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeStartTime | grep "value:" | cut -d ":" -f 3 | tr -d ' '`
    end_time=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeEndTime | grep "value:" | cut -d ":" -f 3 | tr -d ' '`

    if [ "$start_time" = "$end_time" ]
    then
        echo_t "XCONF SCRIPT : Start time can not be equal to end time" >> $XCONF_LOG_FILE
        echo_t "XCONF SCRIPT : Resetting values to default" >> $XCONF_LOG_FILE
        dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeStartTime string "3600"
        dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeEndTime string "14400"
        start_time=3600
        end_time=14400
    fi

    echo_t "XCONF SCRIPT : Firmware upgrade start time : $start_time" >> $XCONF_LOG_FILE
    echo_t "XCONF SCRIPT : Firmware upgrade end time : $end_time" >> $XCONF_LOG_FILE

    #
    # Generate time to check for update
    #
    if [ $1 -eq '1' ]; then
        
        echo_t "XCONF SCRIPT : Check Update time being calculated within 24 hrs."
        echo_t "XCONF SCRIPT : Check Update time being calculated within 24 hrs." >> $XCONF_LOG_FILE

        # Calculate random hour
        # The max random time can be 23:59:59
        rand_hr=`awk -v min=0 -v max=23 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

        echo_t "XCONF SCRIPT : Time Generated : $rand_hr hr $rand_min min $rand_sec sec"
        min_to_sleep=$(($rand_hr*60 + $rand_min))
        sec_to_sleep=$(($min_to_sleep*60 + $rand_sec))

        printf "XCONF SCRIPT : Checking update with XCONF server at \t";
        # date -d "$min_to_sleep minutes" +'%H:%M:%S'
        date -d @"$(( `date +%s`+$sec_to_sleep ))"

        date_upgch_part="$(( `date +%s`+$sec_to_sleep ))"
        date_upgch_final=`date -d @"$date_upgch_part"`

        echo_t "Checking update on $date_upgch_final" >> $XCONF_LOG_FILE

    fi

    #
    # Generate time to downlaod HTTP image
    # device reboot time 
    #
    if [ $2 -eq '1' ]; then

        if [ "$3" == "r" ]; then
            echo_t "XCONF SCRIPT : Device reboot time being calculated in maintenance window"
            echo_t "XCONF SCRIPT : Device reboot time being calculated in maintenance window" >> $XCONF_LOG_FILE
        fi

        if [ "$start_time" -gt "$end_time" ]
        then
            start_time=$(($start_time-86400))
        fi

        #Calculate random value
        random_time=`awk -v min=$start_time -v max=$end_time 'BEGIN{srand(); print int(min+rand()*(max-min+1))}'`

        if [ $random_time -le 0 ]
        then
            random_time=$((random_time+86400))
        fi
        random_time_in_sec=$random_time

        # Calculate random second
        rand_sec=$((random_time%60))

        # Calculate random min
        random_time=$((random_time/60))
        rand_min=$((random_time%60))

        # Calculate random hour
        random_time=$((random_time/60))
        rand_hr=$((random_time%60))

        echo_t "XCONF SCRIPT : Time Generated : $rand_hr hr $rand_min min $rand_sec sec" >> $XCONF_LOG_FILE

        # Get current time
        if [ "$UTC_ENABLE" == "true" ]
        then
            cur_hr=`LTime H | sed 's/^0*//'`
            cur_min=`LTime M | sed 's/^0*//'`
            cur_sec=`date +"%S" | sed 's/^0*//'`
        else
            cur_hr=`date +"%H" | sed 's/^0*//'`
            cur_min=`date +"%M" | sed 's/^0*//'`
            cur_sec=`date +"%S" | sed 's/^0*//'`
        fi
        echo_t "XCONF SCRIPT : Current Local Time: $cur_hr hr $cur_min min $cur_sec sec" >> $XCONF_LOG_FILE

        curr_hr_in_sec=$((cur_hr*60*60))
        curr_min_in_sec=$((cur_min*60))
        curr_time_in_sec=$((curr_hr_in_sec+curr_min_in_sec+cur_sec))
        echo_t "XCONF SCRIPT : Current Time in secs: $curr_time_in_sec sec" >> $XCONF_LOG_FILE

        if [ $curr_time_in_sec -le $random_time_in_sec ]
        then
            sec_to_sleep=$((random_time_in_sec-curr_time_in_sec))
        else
            sec_to_12=$((86400-curr_time_in_sec))
            sec_to_sleep=$((sec_to_12+random_time_in_sec))
        fi

        time=$(( `date +%s`+$sec_to_sleep ))
        date_final=`date -d @${time} +"%T"`

        echo_t "Action on $date_final"
        echo_t "Action on $date_final" >> $XCONF_LOG_FILE
        touch $REBOOT_WAIT
    fi

    echo_t "XCONF SCRIPT : SLEEPING FOR $min_to_sleep minutes or $sec_to_sleep seconds"
    echo_t "XCONF SCRIPT : SLEEPING FOR $min_to_sleep minutes or $sec_to_sleep seconds" >> $XCONF_LOG_FILE

    #echo "XCONF SCRIPT : SPIN 17 : sleeping for 30 sec, *******TEST BUILD***********"
    #sec_to_sleep=30

    sleep $sec_to_sleep
    echo_t "XCONF script : got up after $sec_to_sleep seconds"
    echo_t "XCONF script : got up after $sec_to_sleep seconds" >> $XCONF_LOG_FILE
}

# Get the MAC address of the WAN interface
getMacAddress()
{
        ifconfig  | grep $interface |  grep -v $interface:0 | tr -s ' ' | cut -d ' ' -f5
}

getBuildType()
{
   IMAGENAME=`cat /fss/gw/version.txt | grep imagename: | cut -d ":" -f 2`

   TEMPDEV=`echo $IMAGENAME | grep DEV`
   if [ "$TEMPDEV" != "" ]
   then
       type="DEV"
   fi

   TEMPVBN=`echo $IMAGENAME | grep VBN`
   if [ "$TEMPVBN" != "" ]
   then
       type="VBN"
   fi

   TEMPPROD=`echo $IMAGENAME | grep PROD`
   if [ "$TEMPPROD" != "" ]
   then
       type="PROD"
   fi

   TEMPCQA=`echo $IMAGENAME | grep CQA`
   if [ "$TEMPCQA" != "" ]
   then
       type="GSLB"
   fi

   echo_t "XCONF SCRIPT : image_type is $type"
   echo_t "XCONF SCRIPT : image_type is $type" >> $XCONF_LOG_FILE
}


removeLegacyResources()
{
        #moved Xconf logging to /var/tmp/xconf.txt.0
    if [ -f /etc/Xconf.log ]; then
                rm /etc/Xconf.log
    fi

        echo_t "XCONF SCRIPT : Done Cleanup"
        echo_t "XCONF SCRIPT : Done Cleanup" >> $XCONF_LOG_FILE
}
# Check if it is still in maintenance window
checkMaintenanceWindow()
{
    start_time=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeStartTime | grep "value:" | cut -d ":" -f 3 | tr -d ' '`
    end_time=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeEndTime | grep "value:" | cut -d ":" -f 3 | tr -d ' '`

    if [ "$start_time" -eq "$end_time" ]
    then
        echo_t "XCONF SCRIPT : Start time can not be equal to end time" >> $XCONF_LOG_FILE
        echo_t "XCONF SCRIPT : Resetting values to default" >> $XCONF_LOG_FILE
        dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeStartTime string "3600"
        dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeEndTime string "14400"
        start_time=3600
        end_time=14400
    fi
    echo_t "XCONF SCRIPT : Firmware upgrade start time : $start_time" >> $XCONF_LOG_FILE
    echo_t "XCONF SCRIPT : Firmware upgrade end time : $end_time" >> $XCONF_LOG_FILE

    if [ "$UTC_ENABLE" == "true" ]
    then
        reb_hr=`LTime H | sed 's/^0*//'`
        reb_min=`LTime M | sed 's/^0*//'`
        reb_sec=`date +"%S" | sed 's/^0*//'`
    else
        reb_hr=`date +"%H" | sed 's/^0*//'`
        reb_min=`date +"%M" | sed 's/^0*//'`
        reb_sec=`date +"%S" | sed 's/^0*//'`
    fi

    reb_window=0
    reb_hr_in_sec=$((reb_hr*60*60))
    reb_min_in_sec=$((reb_min*60))
    reb_time_in_sec=$((reb_hr_in_sec+reb_min_in_sec+reb_sec))
    echo_t "XCONF SCRIPT : Current time in seconds : $reb_time_in_sec" >> $XCONF_LOG_FILE

    if [ $start_time -lt $end_time ] && [ $reb_time_in_sec -ge $start_time ] && [ $reb_time_in_sec -lt $end_time ]
    then
        reb_window=1
    elif [ $start_time -gt $end_time ] && [[ $reb_time_in_sec -lt $end_time || $reb_time_in_sec -ge $start_time ]]
    then
        reb_window=1
    else
        reb_window=0
    fi
}
#####################################################Main Application#####################################################

# Determine the env type and url and write to /tmp/Xconf
#type=`printenv model | cut -d "=" -f2`

removeLegacyResources
getBuildType

# Check if the firmware download process is initiated by scheduler or during boot up.
triggeredFrom=""
if [ $1 -eq 1 ]
then
   echo "XCONF SCRIPT : Trigger is from boot" >> $XCONF_LOG_FILE
   triggeredFrom="boot"
elif [ $1 -eq 2 ]
then
   echo "XCONF SCRIPT : Trigger is from cron" >> $XCONF_LOG_FILE
   triggeredFrom="cron"
else
   echo "XCONF SCRIPT : Trigger is Unknown. Set it to boot" >> $XCONF_LOG_FILE
   triggeredFrom="boot"
fi

if [ "$1" == "cleanup" ]; then
	echo_t "XCONF SCRIPT : Cleaning tmp files" >> $XCONF_LOG_FILE
	rm -rf $REBOOT_WAIT $DOWNLOAD_INPROGRESS $deferReboot $NO_DOWNLOAD $ABORT_REBOOT
fi

# If unit is waiting for reboot after image download,we need not have to download image again.
if [ -f $REBOOT_WAIT ]
then
    echo "XCONF SCRIPT : Waiting reboot after download, so exit" >> $XCONF_LOG_FILE
    exit
fi

if [ -f $DOWNLOAD_INPROGRESS ]
then
    echo "XCONF SCRIPT : Download is in progress, exit" >> $XCONF_LOG_FILE
    exit
fi

echo "XCONF SCRIPT : MODEL IS $type" >> $XCONF_LOG_FILE

#Default xconf url
url="https://xconf.xcal.tv/xconf/swu/stb/"

# Override mechanism should work only for non-production build.
if [ "$type" != "PROD" ] && [ "$type" != "prod" ]; then
  if [ -f /nvram/swupdate.conf ]; then
      url=`grep -v '^[[:space:]]*#' /nvram/swupdate.conf`
      echo_t "XCONF SCRIPT : URL taken from /nvram/swupdate.conf override. URL=$url"
      echo_t "XCONF SCRIPT : URL taken from /nvram/swupdate.conf override. URL=$url"  >> $XCONF_LOG_FILE
      CDL_SERVER_OVERRIDE=1
  fi
fi

#s16 echo "$type=$url" > /tmp/Xconf
echo "URL=$url" > /tmp/Xconf
echo_t "XCONF SCRIPT : Values written to /tmp/Xconf are URL=$url"
echo_t "XCONF SCRIPT : Values written to /tmp/Xconf are URL=$url" >> $XCONF_LOG_FILE

# Check if the WAN interface has an ip address, if not , wait for it to receive one
estbIp=`ifconfig $interface | grep "inet addr" | tr -s " " | cut -d ":" -f2 | cut -d " " -f1`
estbIp6=`ifconfig $interface | grep "inet6 addr" | grep "Global" | tr -s " " | cut -d ":" -f2- | cut -d "/" -f1 | tr -d " "`

echo "[ $(date) ] XCONF SCRIPT - Check if the WAN interface has an ip address" >> $XCONF_LOG_FILE

while [ "$estbIp" = "" ] && [ "$estbIp6" = "" ]
do
    echo "[ $(date) ] XCONF SCRIPT - No IP yet! sleep(5)" >> $XCONF_LOG_FILE
    sleep 5

    estbIp=`ifconfig $interface | grep "inet addr" | tr -s " " | cut -d ":" -f2 | cut -d " " -f1`
    estbIp6=`ifconfig $interface | grep "inet6 addr" | grep "Global" | tr -s " " | cut -d ":" -f2- | cut -d "/" -f1 | tr -d " "`

    echo_t "XCONF SCRIPT : Sleeping for an ipv4 or an ipv6 address on the $interface interface "
done

echo_t "XCONF SCRIPT : $interface has an ipv4 address of $estbIp or an ipv6 address of $estbIp6"

    ######################
    # QUERY & DL MANAGER #
    ######################

# Check if new image is available
echo_t "XCONF SCRIPT : Checking image availability at boot up" >> $XCONF_LOG_FILE
if [ ! -e $NO_DOWNLOAD ]
then	
   getFirmwareUpgDetail
fi

if [ "$rebootImmediately" == "true" ];then
    echo_t "XCONF SCRIPT : Reboot Immediately : TRUE!!"
else
    echo_t "XCONF SCRIPT : Reboot Immediately : FALSE."

fi

download_image_success=0
reboot_device_success=0
http_flash_led_disable=0
is_already_flash_led_disable=0
retry_download=0

while [ $download_image_success -eq 0 ];
do

   #skip download if file exist
   if [ -f $NO_DOWNLOAD ]
   then
      break
   fi

    if [ "$isPeriodicFWCheckEnabled" != "true" ]
    then
       # If an image wasn't available, check it's 
       # availability at a random time,every 24 hrs
       while  [ $image_upg_avl -eq 0 ];
       do
         echo_t "XCONF SCRIPT : Rechecking image availability within 24 hrs" 
         echo_t "XCONF SCRIPT : Rechecking image availability within 24 hrs" >> $XCONF_LOG_FILE

         # Sleep for a random time less than 
         # a 24 hour duration 
         calcRandTime 1 0
    
         # Check for the availability of an update   
         getFirmwareUpgDetail
       done
    fi

    if [ ! -f $DOWNLOAD_INPROGRESS ]
    then
        touch $DOWNLOAD_INPROGRESS
    fi

    if [ $image_upg_avl -eq 1 ];then

        #Wait for dnsmasq to start
        DNSMASQ_PID=`pidof dnsmasq`

        while [ "$DNSMASQ_PID" = "" ]
        do
                sleep 10
                echo_t "XCONF SCRIPT : Waiting for dnsmasq process to start"
                echo_t "XCONF SCRIPT : Waiting for dnsmasq process to start" >> $XCONF_LOG_FILE
                DNSMASQ_PID=`pidof dnsmasq`
        done
                echo_t "XCONF SCRIPT : dnsmasq process  started!!"
                echo_t "XCONF SCRIPT : dnsmasq process  started!!" >> $XCONF_LOG_FILE

        echo "$firmwareLocation" > /tmp/xconfdownloadurl

        # Set the url and filename
		if [ $CDL_SERVER_OVERRIDE -eq 1 ];then
			echo_t "XCONF SCRIPT : URL --- $firmwareLocation and NAME --- $firmwareFilename"
			echo_t "XCONF SCRIPT : URL --- $firmwareLocation and NAME --- $firmwareFilename" >> $XCONF_LOG_FILE
			echo \"\" > /tmp/authHeader
			$BIN_PATH/XconfHttpDl set_http_url $firmwareLocation/$firmwareFilename $firmwareFilename

		else
		
        echo_t "XCONF SCRIPT : URL --- $serverUrl and NAME --- $firmwareFilename" >> $XCONF_LOG_FILE

                $BIN_PATH/XconfHttpDl set_http_url $serverUrl $firmwareFilename

		fi		
                set_url_stat=$?

        # If the URL was correctly set, initiate the download
        if [ $set_url_stat -eq 0 ];then

            # An upgrade is available and the URL has ben set
            # Wait to download in the maintenance window if the RebootImmediately is FALSE
            # else download the image immediately

            if [ "$rebootImmediately" == "false" ];then

                                echo_t "XCONF SCRIPT : Reboot Immediately : FALSE. Downloading image now" >> $XCONF_LOG_FILE
            else
                echo_t  "XCONF SCRIPT : Reboot Immediately : TRUE : Downloading image now" >> $XCONF_LOG_FILE
            fi


                # Start the image download
                        echo "[ $(date) ] XCONF SCRIPT  ### httpdownload started ###" >> $XCONF_LOG_FILE
                $BIN_PATH/XconfHttpDl http_download
                http_dl_stat=$?
                        echo "[ $(date) ] XCONF SCRIPT  ### httpdownload completed ###" >> $XCONF_LOG_FILE
                echo_t "XCONF SCRIPT : HTTP DL STATUS $http_dl_stat"
                echo_t "**XCONF SCRIPT : HTTP DL STATUS $http_dl_stat**" >> $XCONF_LOG_FILE

                # If the http_dl_stat is 0, the download was succesful,
            # Indicate a succesful download and continue to the reboot manager

            if [ $http_dl_stat -eq 0 ];then
                echo_t "XCONF SCRIPT : HTTP download Successful" >> $XCONF_LOG_FILE
                # Indicate succesful download
                download_image_success=1
                rm -rf $DOWNLOAD_INPROGRESS
            else
                # Indicate an unsuccesful download
                echo_t "XCONF SCRIPT : HTTP download NOT Successful" >> $XCONF_LOG_FILE
                rm -rf $DOWNLOAD_INPROGRESS
                download_image_success=0
                # Set the flag to 0 to force a requery
                image_upg_avl=0
                if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
			# No need of looping here as we will trigger a cron job at random time
			exit
		fi
            fi

        else
	    download_image_success=0
            # Set the flag to 0 to force a requery
            image_upg_avl=0
            rm -rf $DOWNLOAD_INPROGRESS
 	    if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
                 retry_download=`expr $retry_download + 1`
	     
         	 if [ $retry_download -eq 3 ]
          	 then
             	    echo_t "XCONF SCRIPT : ERROR : URL & Filename not set correctly after 3 retries.Exiting" >> $XCONF_LOG_FILE
        	    exit  
          	 fi
            fi       
	fi
    fi
done

    ##################
    # REBOOT MANAGER #
    ##################

    # Try rebooting the device if :
    # 1. Issue an immediate reboot if still within the maintenance window and phone is on hook
    # 2. If an immediate reboot is not possile ,calculate and remain within the reboot maintenance window
    # 3. The reboot ready status is OK within the maintenance window
    # 4. The rebootImmediate flag is set to true

while [ $reboot_device_success -eq 0 ]; do
                    
    # Verify reboot criteria ONLY if rebootImmediately is FALSE
    if [ "$rebootImmediately" == "false" ];then

        # Check if still within reboot window
        checkMaintenanceWindow

        if [ $reb_window -eq 1 ]; then
            echo_t "XCONF SCRIPT : Still within current maintenance window for reboot"
            echo_t "XCONF SCRIPT : Still within current maintenance window for reboot" >> $XCONF_LOG_FILE
            reboot_now=1
        else
            echo_t "XCONF SCRIPT : Not within current maintenance window for reboot.Rebooting in the next window"
            echo_t "XCONF SCRIPT : Not within current maintenance window for reboot.Rebooting in the next window" >> $XCONF_LOG_FILE
            reboot_now=0
        fi


        if [ $reboot_now -eq 0 ] && [ $is_already_flash_led_disable -eq 0 ];
		then
			echo "XCONF SCRIPT	: ### httpdownload flash LED disabled ###" >> $XCONF_LOG_FILE
			$BIN_PATH/XconfHttpDl http_flash_led $http_flash_led_disable
           	 is_already_flash_led_disable=1
        fi  

        # If we are not supposed to reboot now, calculate random time
        # to reboot in next maintenance window
        if [ $reboot_now -eq 0 ];then
            calcRandTime 0 1 r
        fi

        # Check the Reboot status
        # Continously check reboot status every 10 seconds
        # till the end of the maintenace window until the reboot status is OK
        $BIN_PATH/XconfHttpDl http_reboot_status
        http_reboot_ready_stat=$?

        while [ $http_reboot_ready_stat -eq 1 ]
        do
            sleep 10
            checkMaintenanceWindow

            if [ $reb_window -eq 1 ]
            then
                #We're still within the reboot window
                $BIN_PATH/XconfHttpDl http_reboot_status
                http_reboot_ready_stat=$?

            else
                #If we're out of the reboot window, exit while loop
                break
            fi
        done

    else
        #RebootImmediately is TRUE
        echo_t "XCONF SCRIPT : Reboot Immediately : TRUE!, rebooting device now"
        http_reboot_ready_stat=0
        echo_t "XCONF SCRIPT : http_reboot_ready_stat is $http_reboot_ready_stat"

    fi

    echo_t "XCONF SCRIPT : http_reboot_ready_stat is $http_reboot_ready_stat" >> $XCONF_LOG_FILE

    # The reboot ready status changed to OK within the maintenance window,proceed
    if [ $http_reboot_ready_stat -eq 0 ];then

	if [ $abortReboot_count -lt 5 ];then
		#Wait for Notification to propogate
		deferfw=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.RPC.DeferFWDownloadReboot | grep value | cut -d ":" -f 3 | tr -d ' ' `
		echo_t "XCONF SCRIPT : Sleeping for $deferfw seconds before reboot" >> $XCONF_LOG_FILE
		touch $deferReboot 
		dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.RPC.RebootPendingNotification uint $deferfw
		sleep $deferfw
	else
		echo_t "XCONF SCRIPT : Abort Count reached maximum limit $abortReboot_count" >> $XCONF_LOG_FILE
	fi

        #Abort Reboot
        if [ ! -e "$ABORT_REBOOT" ]
	then

        #Reboot the device
            echo_t "XCONF SCRIPT : Reboot possible. Issuing reboot command"
            echo_t "RDKB_REBOOT : Reboot command issued from XCONF"
                $BIN_PATH/XconfHttpDl http_reboot
                reboot_device=$?

        # This indicates we're within the maintenace window/rebootImmediate=TRUE
        # and the reboot ready status is OK, issue the reboot
        # command and check if it returned correctly
            if [ $reboot_device -eq 0 ];then
            reboot_device_success=1
                     #For rdkb-4260
            echo_t "Creating file /nvram/reboot_due_to_sw_upgrade"
            touch /nvram/reboot_due_to_sw_upgrade
            echo_t "XCONF SCRIPT : REBOOTING DEVICE"
            echo_t "RDKB_REBOOT : Rebooting device due to software upgrade"
            echo_t "XCONF SCRIPT : setting LastRebootReason"
            dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_LastRebootReason string Software_upgrade
            echo_t "XCONF SCRIPT : SET succeeded"


            else
            # The reboot command failed, retry in the next maintenance window
            reboot_device_success=0
            #Goto start of Reboot Manager again
            fi
        else
                echo_t "XCONF SCRIPT : Reboot aborted by user, will try in next maintenance window " >> $XCONF_LOG_FILE
		abortReboot_count=$((abortReboot_count+1))
		echo_t "XCONF SCRIPT : Abort Count is  $abortReboot_count" >> $XCONF_LOG_FILE
                touch $NO_DOWNLOAD
                rm -rf $ABORT_REBOOT
                rm -rf $deferReboot
                reboot_device_success=0
                if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
                      exit
                fi

		while [ 1 ]
		do
		    checkMaintenanceWindow

		    if [ $reb_window -eq 1 ]
		    then
		        #We're still within the maintenance window
		        sleep 600
		    else
		        #If we're out of the maintenance window, exit while loop
		        break
		    fi
		done
       fi

     # The reboot ready status didn't change to OK within the maintenance window
     else
        reboot_device_success=0
            echo_t " XCONF SCRIPT : Device is not ready to reboot : Retrying in next reboot window ";
        # Goto start of Reboot Manager again
     fi

done # While loop for reboot manager

