#!/usr/bin/env bash
#Author: Evgeniy Krasnukhin
#
#Description: Start all database from oratab and starts listeners
#
#DIRSCR=$(pwd)
DIRSCR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
script_ver=161107
info ()
{
    echo -e "\nAuthor: Evgeniy Krasnukhin \nusage:$(basename $0) [options]\n 
NAME
       $(basename $0)  - stop or start  listeners and databases depending on options. You can specify version of rdbms. When option -v are used script stop|start 
databases for specified version. 

OPTIONS
   --ver                version of the script
   --help               show help information
    -c   
        COMMAND         start or stop. start - startup databases. stop - stop databases
    -t
        TYPE            db|lis|all. db - start or stop (depending at option -c) for databases. 
                        lis - start or stop (depending at option -c) only for listeners. 
                        all - start or stop for databases and listeners in oratab file
    -v 
        VERSION_ORACLE  10|11|11203|11204|12|12102|12102j7|all. Startup or stop (option -c) for specified version or for all databases. 
EXAMPLE
      local execution: 
      $(basename $0) -c start -t all -v all    - startup all databases and listeners
      $(basename $0) -c stop -t list -v 12102  - shutdown only listeners for version 12102       
      $(basename $0) -c start -t all -v 12102  - startup db and listeners for version 12102
"
}                                                                            

#########MAIN###############
[ -f $DIRSCR/init.sh ] && . $DIRSCR/init.sh || { echo "Can't source file $DIRSCR/init.sh "; exit 1; }
[ -f $COMDIR/functions.sh ] && . $COMDIR/functions.sh || { echo "Can't source file $COMDIR/functions.sh "; exit 1; }
[ -f $COMDIR/job-pool-screen.sh ] && . $COMDIR/job-pool-screen.sh || { echo "Can't source file $COMDIR/job-pool-screen.sh "; exit 1; }
menu $1
while getopts "c:t:v:" opt
do
    checkargs
    case $opt in
        c)
            case "$OPTARG" in
                'start')
                    flagman="start"
                    ;;
                'stop')
                    flagman="stop"
                    ;;
                *)
                    echo "Incorrect value for option -c. Use: start|stop."
                    exit 1;
                    ;;
            esac
            
            ;;

        t)
            type="$OPTARG"
            if [ "$type" != db  ] && [ "$type" != lis ] && [ "$type" != all ]; then
                echo "Incorrect value for option -t. Use: db|lis|all"
                exit 1
            fi
            ;;
        v)
            ver="$OPTARG"
            case $ver in
                10)
                    ver=o"10204"
                    ;;
                
                11)
                    ver=o"11204"
                    ;;
                11203)
                    ver=o"11203"
                    ;;
                11204)
                    ver=o"11204"
                    ;;
                11204se)
                    ver=o"11204se"
                    ;;
                12)
                    ver=o"12102"
                    ;;
                12102)
                    ver=o"12102"
                    ;;
                12102j7)
                    ver=o"1210j7"
                    ;;
                12102se)
                    ver=o"12102se"
                    ;;
                all)
                    ver=all
                    ;;
                *)
                    echo "Incorrect version. Use 10|11|11203|11204|12|12102|all"
                    exit 1;
            esac
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
        :)
            echo "option -$OPTARG requires an argument" >&2
            exit 1
            ;;
       esac
done

#mandatory options
[ -z "$flagman" ] && { echo "-c [option] is required"; exit 1; }
[ -z "$type" ] && { echo "-t [option] is required"; exit 1; }
[ -z "$ver" ] && { echo "-v [option] is required"; exit 1; }

echo "Version = $ver"
echo "Type = $type "
echo "Command = $flagman"

if [ "$ver" != all ]; then
    if ! grep "^${ver}:" $oratab &>/dev/null; then
        echo "No such version $ver"
        exit 1;
    else
        OH=$(perl -F: -lane 'print $F[1] if /^'$ver':/' $oratab)
    fi
    #SIDS=$( perl -ne 'if (/'$ver:'/) { print; while (<>) { next if /^\s*$/; if (/##+/) {last} else { print } }; last unless $_ }' $oratab | perl -F: -lane 'print $F[0]')
    SIDS=$(perl -F: -lane 'print $F[0]  if m{^[^#].*'$OH'}' $oratab)
else
    
    SIDS=$(perl -F: -lane 'print($F[0]) if $F[0] !~ /^\s*(#|$)/' $oratab)  # alternative perl awk -F: '$1 !~ /^\s*(#|$)/ {print $1}'

fi
#for start command
[ -z "$count_sid" ] && count_sid=$(echo "$SIDS" | grep -v "^o" | wc -l)    

echo "List of sids:"
#echo "$SIDS" | grep -v "^o"
echo $SIDS
echo "Number of sids = $count_sid"
export ORAENV_ASK=NO

if [[ "$type" = db ]]; then
    flagdb=1
elif [[ "$type" = lis ]]; then
    flaglis=1
else
    flagdb=1
    flaglis=1
fi

arr_cmd=()
for SID in  $(echo "$SIDS") #$(perl -F: -lane 'print($F[0]) if $F[0] !~ /^\s*(#|$)/' $oratab)  # alternative perl awk -F: '$1 !~ /^\s*(#|$)/ {print $1}'
do
    export ORACLE_SID=$SID
    . oraenv &>/dev/null
    if  ! echo $SID | grep "^o" &>/dev/null; then
        if [[ $flagman = start ]] && [[ $flagdb -eq 1 ]]; then
            #echo -e "\n##########################startup_db $SID###################################"
            #screen -d -m bash -c "startup_db $SID"
            arr_cmd+=("export ORAENV_ASK=NO;export ORACLE_SID=$SID; . oraenv;startup_db $SID")
        elif [[ $flagman = stop ]] && [[ $flagdb -eq 1 ]]; then
            
            if pgrep -fx ora_pmon_$ORACLE_SID &>/dev/null; then
                #echo -e "\n##########################shut_db $SID###################################"
                arr_cmd+=("export ORAENV_ASK=NO;export ORACLE_SID=$SID; . oraenv; shut_db $SID")
            fi
        fi        
    else
        # startup listener
        if [[ $flaglis -eq 1 ]]; then 
            ARR_LIS=($(perl -ln -e 'print $1 if (/^((?:oralist|mgw|extlist)\d*[a-z0-9]*)[ \t]*=/i)'  $ORACLE_HOME/network/admin/listener.ora))
            echo "array=${ARR_LIS[@]}"
            for lis in  ${ARR_LIS[@]}
            do
                echo -e "\n################lsnrctl $flagman $lis####################"
		if [[ "$lis" = extlist* ]] || [[ "$lis" = EXTLIST* ]]; then
		    sudo -E -u ibs -s <<-EOF
$ORACLE_HOME/bin/lsnrctl $flagman $lis
EOF
# 		    sudo -E -u ibs -s <<-EOF
# $ORACLE_HOME/bin/lsnrctl status $lis
# EOF
		else
                    lsnrctl $flagman $lis
                    #lsnrctl status $lis
		fi
            done
	fi
        
    fi
    
done

export -f startup_db
export -f shut_db
echo arr_cmd="${arr_cmd[@]}"

if [[ -n ${arr_cmd[@]} ]] ;then
   run_job_pool "${arr_cmd[@]}"
fi

unset -f startup_db
unset -f shut_db
