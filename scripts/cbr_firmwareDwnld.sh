#!/bin/sh

if [ -f /etc/device.properties ]
then
    source /etc/device.properties
fi

XCONF_LOG_PATH=/rdklogs/logs
XCONF_LOG_FILE_NAME=xconf.txt.0
XCONF_LOG_FILE_PATHNAME=${XCONF_LOG_PATH}/${XCONF_LOG_FILE_NAME}
XCONF_LOG_FILE=${XCONF_LOG_FILE_PATHNAME}

CURL_PATH=/bin
interface=erouter0
BIN_PATH=/bin
CURL_REQUEST=""
#GLOBAL DECLARATIONS
image_upg_avl=0
reb_window=0

echo_t()
{
	    echo "`date +"%y%m%d-%T.%6N"` $1"
}

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


#This function will not check any other criteria other than matching current firmware and requested firmware

checkFirmwareUpgCriteria()
{
	image_upg_avl=0

	currentVersion=`cat /version.txt | grep "imagename:" | cut -d ":" -f 2`

        #Comcast signed firmware images are represented in lower case and vendor signed images are represented in upper case. 
        #In order to avoid confusion in string comparison, converting both currentVersion and firmwareVersion to lower case.
	currentVersion=`echo $currentVersion | tr '[A-Z]' '[a-z]'`
        firmwareVersion=`echo $firmwareVersion | tr '[A-Z]' '[a-z]'`
	
	echo_t "XCONF SCRIPT : CurrentVersion : $currentVersion"
        echo_t "XCONF SCRIPT : UpgradeVersion : $firmwareVersion"

        echo_t "XCONF SCRIPT : CurrentVersion : $currentVersion" >> $XCONF_LOG_FILE
        echo_t "XCONF SCRIPT : UpgradeVersion : $firmwareVersion" >> $XCONF_LOG_FILE
	
	if [ "$currentVersion" != "" ] && [ "$firmwareVersion" != "" ];then
		if [ "$currentVersion" == "$firmwareVersion" ]; then
			echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are same. No upgrade/downgrade required"
			echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are same. No upgrade/downgrade required">> $XCONF_LOG_FILE
			image_upg_avl=0
		else
			echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are different. Processing Upgrade/Downgrade"
			echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are different. Processing Upgrade/Downgrade">> $XCONF_LOG_FILE
			image_upg_avl=1
		fi
	else
		echo_t "XCONF SCRIPT : Current image ("$currentVersion") Or Requested image ("$firmwareVersion") returned NULL. No Upgrade/Downgrade"
		echo_t "XCONF SCRIPT : Current image ("$currentVersion") Or Requested image ("$firmwareVersion") returned NULL. No Upgrade/Downgrade">> $XCONF_LOG_FILE
		image_upg_avl=0
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

    echo_t "XCONF SCRIPT : env is $env"
    echo_t "XCONF SCRIPT : xconf url  is $xconf_url"

    # Check with the XCONF server if an update is available 
    while [ $xconf_retry_count -le 3 ] && [ $retry_flag -eq 1 ]
    do

        echo_t "**RETRY is $xconf_retry_count and RETRY_FLAG is $retry_flag**" >> $XCONF_LOG_FILE
        
        # White list the Xconf server url
        #echo_t "XCONF SCRIPT : Whitelisting Xconf Server url : $xconf_url"
        #echo_t "XCONF SCRIPT : Whitelisting Xconf Server url : $xconf_url" >> $XCONF_LOG_FILE
        #/etc/whitelist.sh "$xconf_url"
        
	# Perform cleanup by deleting any previous responses
	rm -f /tmp/response.txt /tmp/XconfOutput.txt
	firmwareDownloadProtocol=""
	firmwareFilename=""
	firmwareLocation=""
	firmwareVersion=""
	rebootImmediately=""
        ipv6FirmwareLocation=""
        upgradeDelay=""
       
#TODO
        currentVersion=`cat /version.txt | grep "imagename:" | cut -d ":" -f 2`
#TODO
        devicemodel=`dmcli eRT getv Device.DeviceInfo.ModelName  | grep "value:" | cut -d ":" -f 3 | tr -d ' ' `
        MAC=`ifconfig $interface  | grep HWaddr | cut -d' ' -f7`
        date=`date`
        
        echo_t "XCONF SCRIPT : CURRENT VERSION : $currentVersion"
        echo_t "XCONF SCRIPT : CURRENT MAC  : $MAC"
        echo_t "XCONF SCRIPT : CURRENT DATE : $date"
	echo_t "XCONF SCRIPT : DEVICE MODEL : $devicemodel"

        # Query the  XCONF Server
	#CURL_REQUEST variable is added only for logging purpose. This is not the curl execution
	CURL_REQUEST="curl --interface $interface -k -w '%{http_code}\n' -d \"eStbMac=$MAC&firmwareVersion=$currentVersion&env=$env&model=$devicemodel&localtime=$date&timezone=EST05&capabilities=\"rebootDecoupled\"&capabilities=\"RCDL\"&capabilities=\"supportsFullHttpUrl\"\" -o \"/tmp/response.txt\" \"$xconf_url\" --connect-timeout 30 -m 30"
	echo "`date +"%y%m%d-%T.%6N"` XCONF SCRIPT : CURL_REQUEST executing is : $CURL_REQUEST" 

	# Query the  XCONF Server
	HTTP_RESPONSE_CODE=`curl --interface $interface -k -w '%{http_code}\n' -d "eStbMac=$MAC&firmwareVersion=$currentVersion&env=$env&model=$devicemodel&localtime=$date&timezone=EST05&capabilities="rebootDecoupled"&capabilities="RCDL"&capabilities="supportsFullHttpUrl"" -o "/tmp/response.txt" "$xconf_url" --connect-timeout 30 -m 30`
	    
        echo "`date +"%y%m%d-%T.%6N"` XCONF SCRIPT : HTTP RESPONSE CODE is $HTTP_RESPONSE_CODE"


	# Print the response
	echo_t "XCONF SCRIPT : Print the response -> output of /tmp/response.txt after curl execution is as below"
        cat /tmp/response.txt
        cat "/tmp/response.txt" >> $XCONF_LOG_FILE

	if [ $HTTP_RESPONSE_CODE -eq 200 ];then
            retry_flag=0
			
	    OUTPUT="/tmp/XconfOutput.txt" 
            cat "/tmp/response.txt" | tr -d '\n' | sed 's/[{}]//g' | awk  '{n=split($0,a,","); for (i=1; i<=n; i++) print a[i]}' | sed 's/\"\:\"/\|/g' | sed -r 's/\"\:(true)($)/\|true/gI' | sed -r 's/\"\:(false)($)/\|false/gI' | sed -r 's/\"\:(null)($)/\|\1/gI' | sed -r 's/\"\:([0-9]+)($)/\|\1/g' | sed 's/[\,]/ /g' | sed 's/\"//g' > $OUTPUT
			
	    firmwareDownloadProtocol=`grep firmwareDownloadProtocol $OUTPUT  | cut -d \| -f2`

	    if [ "$firmwareDownloadProtocol" == "http" ];then
                echo -e "\n"
		echo_t "XCONF SCRIPT : Download image from HTTP server" 
                firmwareLocation=`grep firmwareLocation $OUTPUT | cut -d \| -f2 | tr -d ' '`
            else
                echo -e "\n"
                echo_t "XCONF SCRIPT : Download from TFTP server not supported, check XCONF server configurations"
                echo_t "XCONF SCRIPT : Retrying query in 2 minutes"
                
                # sleep for 2 minutes and retry
                sleep 120;

                retry_flag=1
                image_upg_avl=0

                #Increment the retry count
                xconf_retry_count=$((xconf_retry_count+1))

                continue
            fi

    	    firmwareFilename=`grep firmwareFilename $OUTPUT | cut -d \| -f2`
    	    firmwareVersion=`grep firmwareVersion $OUTPUT | cut -d \| -f2`
	    ipv6FirmwareLocation=`grep ipv6FirmwareLocation  $OUTPUT | cut -d \| -f2 | tr -d ' '`
	    upgradeDelay=`grep upgradeDelay $OUTPUT | cut -d \| -f2`
            rebootImmediately=`grep rebootImmediately $OUTPUT | cut -d \| -f2`     
                                    
    	    echo_t "XCONF SCRIPT : Protocol :"$firmwareDownloadProtocol
    	    echo_t "XCONF SCRIPT : Filename :"$firmwareFilename
    	    echo_t "XCONF SCRIPT : Location :"$firmwareLocation
    	    echo_t "XCONF SCRIPT : Version  :"$firmwareVersion
    	    echo_t "XCONF SCRIPT : Reboot   :"$rebootImmediately
	
            if [ "X"$firmwareLocation = "X" ];then
                echo_t "XCONF SCRIPT : No URL received in /tmp/response.txt" >> $XCONF_LOG_FILE
                retry_flag=1
                image_upg_avl=0

                #Increment the retry count
                xconf_retry_count=$((xconf_retry_count+1))

            else
                echo_t "$firmwareLocation" > /tmp/.xconfssrdownloadurl
           	# Check if a newer version was returned in the response
            # If image_upg_avl = 0, retry reconnecting with XCONf in next window
            # If image_upg_avl = 1, download new firmware
     
		checkFirmwareUpgCriteria

	    fi
		

        # If a response code of 404 was received, error
	elif [ $HTTP_RESPONSE_CODE -eq 404 ]; then 
        	retry_flag=0
           	image_upg_avl=0
        echo_t "XCONF SCRIPT : Response code received is 404" >> $XCONF_LOG_FILE
        # If a response code of 0 was received, the server is unreachable
        # Try reconnecting 
        elif [ $HTTP_RESPONSE_CODE -eq 0 ]; then
            
            echo_t "XCONF SCRIPT : Response code 0, sleeping for 2 minutes and retrying" >>$XCONF_LOG_FILE
            # sleep for 2 minutes and retry
            sleep 120;

            retry_flag=1
            image_upg_avl=0

           	#Increment the retry count
           	xconf_retry_count=$((xconf_retry_count+1))

        fi

    done

    if [ $xconf_retry_count -eq 4 ];then
        echo_t "XCONF SCRIPT : Retry limit to connect with XCONF server reached" 
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

    if [ "$start_time" -eq "$end_time" ]
    then
        echo_t "XCONF SCRIPT : Start time can not be equal to end time"
        echo_t "XCONF SCRIPT : Resetting values to default"
        echo_t "XCONF SCRIPT : Start time can not be equal to end time" >> $XCONF_LOG_FILE
        echo_t "XCONF SCRIPT : Resetting values to default" >> $XCONF_LOG_FILE
        dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeStartTime string "0"
        dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeEndTime string "10800"
        start_time=0
        end_time=10800
    fi

    echo_t "XCONF SCRIPT : Firmware upgrade start time : $start_time"
    echo_t "XCONF SCRIPT : Firmware upgrade end time : $end_time"
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

        printf "`date +"%y%m%d-%T.%6N"` XCONF SCRIPT : Checking update with XCONF server at ";
        # date -d "$min_to_sleep minutes" +'%H:%M:%S'
        # date -D '%s' -d "$(( `date +%s`+$sec_to_sleep ))"
        time=$(( `date +%s`+$sec_to_sleep ))
        date -d @${time} +"%T"

        date_upgch_part="$(( `date +%s`+$sec_to_sleep ))"
        # date_upgch_final=`date -D '%s' -d "$date_upgch_part"`
        date_upgch_final=`date -d @${date_upgch_part} +"%T"`

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

        echo_t "XCONF SCRIPT : Time Generated : $rand_hr hr $rand_min min $rand_sec sec"
        echo_t "XCONF SCRIPT : Time Generated : $rand_hr hr $rand_min min $rand_sec sec" >> $XCONF_LOG_FILE

        # Get current time
        if [ "$UTC_ENABLE" == "true" ]
        then
            cur_hr="10#"`LTime H`
            cur_min="10#"`LTime M`
            cur_sec="10#"`date +"%S"`
        else
            cur_hr="10#"`date +"%H"`
            cur_min="10#"`date +"%M"`
            cur_sec="10#"`date +"%S"`
        fi

        curr_hr_in_sec=$((cur_hr*60*60))
        curr_min_in_sec=$((cur_min*60))
        curr_time_in_sec=$((curr_hr_in_sec+curr_min_in_sec+cur_sec))

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

    fi

    echo_t "XCONF SCRIPT : SLEEPING FOR $sec_to_sleep seconds"
    echo_t "XCONF SCRIPT : SLEEPING FOR $sec_to_sleep seconds" >> $XCONF_LOG_FILE

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
   IMAGENAME=`cat /version.txt | grep "imagename:" | cut -d ":" -f 2`
   
   #Assigning default type as DEV
   type="DEV"
   echo_t "XCONF SCRIPT : Assigning default image type as: $type"

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
   
   echo_t "XCONF SCRIPT : image_type returned from version.txt is $type"
   echo_t "XCONF SCRIPT : image_type returned from version.txt is $type" >> $XCONF_LOG_FILE
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
        echo_t "XCONF SCRIPT : Start time can not be equal to end time"
        echo_t "XCONF SCRIPT : Resetting values to default"
        echo_t "XCONF SCRIPT : Start time can not be equal to end time" >> $XCONF_LOG_FILE
        echo_t "XCONF SCRIPT : Resetting values to default" >> $XCONF_LOG_FILE
        dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeStartTime string "0"
        dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeEndTime string "10800"
        start_time=0
        end_time=10800
    fi

    echo_t "XCONF SCRIPT : Firmware upgrade start time : $start_time"
    echo_t "XCONF SCRIPT : Firmware upgrade start time : $start_time" >> $XCONF_LOG_FILE
    echo_t "XCONF SCRIPT : Firmware upgrade end time : $end_time"
    echo_t "XCONF SCRIPT : Firmware upgrade end time : $end_time" >> $XCONF_LOG_FILE

    if [ "$UTC_ENABLE" == "true" ]
    then
        reb_hr="10#"`LTime H`
        reb_min="10#"`LTime M`
        reb_sec="10#"`date +"%S"`
    else
        reb_hr="10#"`date +"%H"`
        reb_min="10#"`date +"%M"`
        reb_sec="10#"`date +"%S"`
    fi

    reb_window=0
    reb_hr_in_sec=$((reb_hr*60*60))
    reb_min_in_sec=$((reb_min*60))
    reb_time_in_sec=$((reb_hr_in_sec+reb_min_in_sec+reb_sec))
    echo_t "XCONF SCRIPT : Current time in seconds : $reb_time_in_sec"
    echo_t "XCONF SCRIPT : Current time in seconds : $reb_time_in_sec" >> $XCONF_LOG_FILE

    if [ $start_time -lt $end_time ] && [ $reb_time_in_sec -ge $start_time ] && [ $reb_time_in_sec -lt $end_time ]
    then
        reb_window=1
    elif [[ ($start_time -gt $end_time) && ( $reb_time_in_sec -lt $end_time || $reb_time_in_sec -ge $start_time ) ]];then
        reb_window=1
    else
        reb_window=0
    fi
}

#####################################################Main Application#####################################################

#Setting up the iptable rule that needed for ci-xconf to communicate
#This need to be removed once we have proper firewall settings

iptables -t mangle -A OUTPUT -o erouter0 -j DSCP --set-dscp-class AF32

# Determine the env type and url and write to /tmp/Xconf
#type=`printenv model | cut -d "=" -f2`

removeLegacyResources
getBuildType

echo_t "XCONF SCRIPT : IMAGE TYPE SET AS $type"

if [ "$type" == "DEV" ] || [ "$type" == "dev" ];then
    #url="https://xconf.poa.xcal.tv/xconf/swu/stb/"
    url="https://ci.xconfds.ccp.xcal.tv/xconf/swu/stb/"
else
    url="https://xconf.xcal.tv/xconf/swu/stb/"
fi

# Override mechanism should work only for non-production build.
if [ -f /nvram/swupdate.conf ]; then
  if [ "$type" != "PROD" ] && [ "$type" != "prod" ]; then
      url=`grep -v '^[[:space:]]*#' /nvram/swupdate.conf`
      echo_t "XCONF SCRIPT : Non PROD build. URL taken from /nvram/swupdate.conf override. URL=$url"  >> $XCONF_LOG_FILE
      echo_t "XCONF SCRIPT : Non PROD build. URL taken from /nvram/swupdate.conf override. URL=$url"
  else
     echo_t "XCONF SCRIPT : PROD build found. Ignoring /nvram/swupdate.conf override. URL=$url" >> $XCONF_LOG_FILE
     echo_t "XCONF SCRIPT : PROD build found. Ignoring /nvram/swupdate.conf override. URL=$url"
  fi
fi

#s16 echo_t "$type=$url" > /tmp/Xconf
echo_t "URL=$url" > /tmp/Xconf
echo_t "XCONF SCRIPT : Values written to /tmp/Xconf are URL=$url"
echo_t "XCONF SCRIPT : Values written to /tmp/Xconf are URL=$url" >> $XCONF_LOG_FILE

# Check if the WAN interface has an ip address, if not , wait for it to receive one
estbIp=`ifconfig $interface | grep "inet addr" | tr -s " " | cut -d ":" -f2 | cut -d " " -f1`
estbIp6=`ifconfig $interface | grep "inet6 addr" | grep "Global" | tr -s " " | cut -d ":" -f2- | cut -d "/" -f1 | tr -d " "`

echo_t "[ $(date) ] XCONF SCRIPT - Check if the WAN interface has an ip address" >> $XCONF_LOG_FILE

while [ "$estbIp" = "" ] && [ "$estbIp6" = "" ]
do
    echo_t "[ $(date) ] XCONF SCRIPT - No IP yet! sleep(5)" >> $XCONF_LOG_FILE
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
getFirmwareUpgDetail

if [ "$rebootImmediately" == "true" ];then
    echo_t "XCONF SCRIPT : Reboot Immediately : TRUE!!"
else
    echo_t "XCONF SCRIPT : Reboot Immediately : FALSE."

fi    

download_image_success=0
reboot_device_success=0

while [ $download_image_success -eq 0 ]; 
do
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

    if [ $image_upg_avl -eq 1 ];then

        #Wait for dnsmasq to start
#DNSMASQ_PID=`pidof dnsmasq`
#
#       while [ "$DNSMASQ_PID" = "" ]
#       do
#           sleep 10
#           echo_t "XCONF SCRIPT : Waiting for dnsmasq process to start"
#           echo_t "XCONF SCRIPT : Waiting for dnsmasq process to start" >> $XCONF_LOG_FILE
#           DNSMASQ_PID=`pidof dnsmasq`
#       done
#
#       echo_t "XCONF SCRIPT : dnsmasq process  started!!"
#       echo_t "XCONF SCRIPT : dnsmasq process  started!!" >> $XCONF_LOG_FILE
    
        # Whitelist the returned firmware location
        #echo_t "XCONF SCRIPT : Whitelisting download location : $firmwareLocation"
        #echo_t "XCONF SCRIPT : Whitelisting download location : $firmwareLocation" >> $XCONF_LOG_FILE
        echo "$firmwareLocation" > /tmp/xconfdownloadurl
        #/etc/whitelist.sh "$firmwareLocation"

        # Set the url and filename
        echo_t "XCONF SCRIPT : URL --- $firmwareLocation and NAME --- $firmwareFilename"
        echo_t "XCONF SCRIPT : URL --- $firmwareLocation and NAME --- $firmwareFilename" >> $XCONF_LOG_FILE
        XconfHttpDl set_http_url $firmwareLocation $firmwareFilename >> $XCONF_LOG_FILE
        set_url_stat=$?
        
        # If the URL was correctly set, initiate the download
        if [ $set_url_stat -eq 0 ];then
        
            # An upgrade is available and the URL has ben set 
            # Wait to download in the maintenance window if the RebootImmediately is FALSE
            # else download the image immediately

            if [ "$rebootImmediately" == "false" ];then

				echo_t "XCONF SCRIPT : Reboot Immediately : FALSE. Downloading image now"
				echo_t "XCONF SCRIPT : Reboot Immediately : FALSE. Downloading image now" >> $XCONF_LOG_FILE
            else
                echo_t  "XCONF SCRIPT : Reboot Immediately : TRUE : Downloading image now"
                echo_t  "XCONF SCRIPT : Reboot Immediately : TRUE : Downloading image now" >> $XCONF_LOG_FILE
            fi
			
			#echo_t "XCONF SCRIPT : Sleep to prevent gw refresh error"
			#echo_t "XCONF SCRIPT : Sleep to prevent gw refresh error" >> $XCONF_LOG_FILE
            #sleep 60

	        # Start the image download
			echo_t "[ $(date) ] XCONF SCRIPT  ### httpdownload started ###" >> $XCONF_LOG_FILE
	        XconfHttpDl http_download >> $XCONF_LOG_FILE
	        http_dl_stat=$?
		echo -e "\n"
		echo_t "[ $(date) ] XCONF SCRIPT  ### httpdownload completed ###" >> $XCONF_LOG_FILE
	        echo_t "XCONF SCRIPT : HTTP DL STATUS $http_dl_stat"
	        echo_t "**XCONF SCRIPT : HTTP DL STATUS $http_dl_stat**" >> $XCONF_LOG_FILE
			
	        # If the http_dl_stat is 0, the download was succesful,          
            # Indicate a succesful download and continue to the reboot manager
		
            if [ $http_dl_stat -eq 0 ];then
                echo_t "XCONF SCRIPT : HTTP download Successful" >> $XCONF_LOG_FILE
                # Indicate succesful download
                download_image_success=1
            else
                # Indicate an unsuccesful download
                echo_t "XCONF SCRIPT : HTTP download NOT Successful" >> $XCONF_LOG_FILE
                download_image_success=0
                # Set the flag to 0 to force a requery
                image_upg_avl=0
            fi

        else
            echo_t "XCONF SCRIPT : ERROR : URL & Filename not set correctly.Requerying "
            echo_t "XCONF SCRIPT : ERROR : URL & Filename not set correctly.Requerying " >> $XCONF_LOG_FILE
            # Indicate an unsuccesful download
            download_image_success=0
            # Set the flag to 0 to force a requery
            image_upg_avl=0
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

        # If we are not supposed to reboot now, calculate random time
        # to reboot in next maintenance window 
        if [ $reboot_now -eq 0 ];then
            calcRandTime 0 1 r
        fi    

        # Check the Reboot status
        # Continously check reboot status every 10 seconds  
        # till the end of the maintenace window until the reboot status is OK
        XconfHttpDl http_reboot_status >> $XCONF_LOG_FILE
        http_reboot_ready_stat=$?

        while [ $http_reboot_ready_stat -eq 1 ]   
        do     
            sleep 10
            checkMaintenanceWindow

            if [ $reb_window -eq 1 ]
            then
                #We're still within the reboot window 
                XconfHttpDl http_reboot_status >> $XCONF_LOG_FILE
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
		        
        #Reboot the device
	    echo_t "XCONF SCRIPT : Reboot possible. Issuing reboot command"
	    echo_t "RDKB_REBOOT : Reboot command issued from XCONF"
		XconfHttpDl http_reboot >> $XCONF_LOG_FILE 
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

     # The reboot ready status didn't change to OK within the maintenance window 
     else
        reboot_device_success=0
	echo_t " XCONF SCRIPT : Device is not ready to reboot : Retrying in next reboot window ";
        # Goto start of Reboot Manager again  
     fi
                    
done # While loop for reboot manager