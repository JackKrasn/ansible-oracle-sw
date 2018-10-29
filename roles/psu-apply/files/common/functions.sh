#!/usr/bin/env bash 
#export CS=/dev/shm/count_sid
export PATH=$PATH:/usr/local/bin
checkargs ()
{
    if [[ "$OPTARG" == -* ]]; then 
        echo "Incorrect argument  for parameter: -$opt"
        exit 1;
    fi
}
menu ()
{
    case $1 in
        '--ver')
            echo "Script version ${script_ver}"
            exit 1;
            ;;
        '--help')
            info
            exit 1;
            ;;
        "")
            info
            exit 1;
            ;;
    esac
}

# trap_commands()
# {
#     echo "$ORACLE_SID" >> /tmp/$(basename $0).err
#     if [ -f $CS ]; then
#         . $CS
#         ((--count_sid))
#         echo "count_sid=$count_sid" > $CS
#     fi
#     exit 1
# }
bkp_ctl_trace()
{
    errors "critical"
    local CTLFILE_TRC="$1"
    err="Backup controlfile to trace: Error"
    echo -ne "\nBackup controlfile to trace: "
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
set feedback off pagesize 0 verify off
whenever oserror exit oscode
whenever sqlerror exit sql.sqlcode
alter database backup controlfile to trace as '$CTLFILE_TRC' resetlogs;
quit;
EOF
    echo "Success"
    err=""
}

startup_db()
{
    local export ORACLE_SID=$1
    local DETAIL=$2
    local role
    echo -e "\nStart up $DETAIL database $ORACLE_SID mount \n"
    sqlplus -s / as sysdba <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
startup mount;
exit
EOF
   role=$(sqlplus -s / as sysdba <<-\EOF
set pagesize 0 verify off feedback off
select controlfile_type from v$database;
EOF
       ) 
   if [[ "$role" = STANDBY ]] ; then
       echo "Startup recover for standby "
       $ORACLE_HOME/bin/sqlplus -s / as sysdba <<-\EOFsql2
WHENEVER SQLERROR EXIT SQL.SQLCODE
prompt ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;;
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;
exit
EOFsql2
   else
       echo "Open database"
       $ORACLE_HOME/bin/sqlplus -s "/ as sysdba"  <<-\EOFsql1
WHENEVER SQLERROR EXIT SQL.SQLCODE
prompt ALTER DATABASE OPEN;;
ALTER DATABASE OPEN;
exit
EOFsql1
   fi
}
cpbar()
{
    local SOURCE=$1
    local DEST=$2
    cp -r $SOURCE  $DEST &    
    sleep 5
    s_dir1=`du -s $SOURCE | awk '{ print $1}'`
    s_dir2=`du -s $DEST | awk '{ print $1}'`
    while [ -n "$(pgrep -f "cp -r $SOURCE $DEST")" ]; do
        per=$(($s_dir2*100/$s_dir1))
        printf "\r Copying $SOURCE=`du -sh $SOURCE |awk '{print $1}'` in $DEST  $sym$per%%"
        sleep 1;
        s_dir2=$(du -s $DEST | awk '{ print $1}' )
        if [ $((per-per_old)) -ge 5 ]; then
            sym="$sym|";
            per_old=$per;
        fi
    done
    sleep 1
    s_dir1=$(du -sh $SOURCE | perl -ne '/([0-9]+\.?[0-9]*)/ && print $1')
    s_dir2=$(du -sh $DEST | perl -ne '/([0-9]+\.?[0-9]*)/ && print $1')
    if [ $s_dir1 = $s_dir2 ] ;then
        printf "\r Copying $SOURCE=${s_dir1} in $DEST  ${sym}100%%"
    else
        echo -e "\nCopying database ends with warnings"
        return 1
    fi
}

rsbar()
{
    local SOURCE=$1
    local DEST=$2
    local source_szdb=$(($3/1024/1024))

    if [ -z "$SOURCE" ] || [ -z "$DEST"  ] || [  -z  "$source_szdb" ]; then
	echo "Rsync progress bar: Incorrect input parameters"
	return 1;
    fi
    
    rsync -a --exclude="*temp*" $flagundo  --exclude="*control*ctl" --exclude="*log"  $SOURCE/ $DEST &
    
    sleep 1

    dest_szdb=$(du -sm $DEST | awk '{ print $1}')

    while jobs %% &>/dev/null; do
        per=$(($dest_szdb*100/$source_szdb))
        printf "\r Copying $SOURCE=$((source_szdb/1024)) in $DEST  $sym$per%%"
        sleep 1;
        dest_szdb=$(du -sm $DEST | awk '{ print $1}')
        if [ $((per-per_old)) -ge 5 ]; then
            sym="$sym|";
            per_old=$per;
        fi
    done
    sleep 1
    
    printf "\r Copying $SOURCE=$source_szdb in $DEST  ${sym}100%%"
    
}


fnd_profile()
{
    local STR=$1
    local ORA_HOME
    local pid
    local PROFILE
    
    pid=$( [ -n "$unix" ] && export $unix; ps -ef | grep -wi $STR | grep -v grep | awk {'print $2'})
    #    echo $pid
    if [ -n "$pid" ] ; then
        case $flagos in
            '0')
                export ORACLE_HOME=$(cat /proc/$pid/environ |  sed 's/\x0/\n/g' | grep -w ORACLE_HOME |  sed 's:^.*=\(.*\):\1:')
                ;;
            '1')
                export ORACLE_HOME=$(pargs -e $pid | grep ORACLE_HOME | sed 's:^.*=\(.*\):\1:')
                ;;
            '3')
                export ORACLE_HOME=$(pfiles $pid  | grep bin | awk '{print $2}' | sed 's:\(^.*\)/bin.*:\1:')
                ;;
        esac
    else
        return 1
    fi
    ORA_HOME=$(echo $ORACLE_HOME | sed 's:^.*\(/product.*\)$:\1:;s:/$::')
    PROFILE=$(grep -l $ORA_HOME ~/profile* | egrep -v "~|#")

    if [[ -n $PROFILE ]];then
        printf "%s" $PROFILE
    else
        return 1
    fi
}
check_size()
{
    local SOURCE_DB=$1
    local DEST_DB=$(echo $2 | sed 's:\(^.*\)/.*:\1:')
    size_ava=`df -TP $DEST_DB| awk {'print $5'}| sed -n '2p'`
    size_db=`du -sk $SOURCE_DB | awk '{print $1}'`
    if [ $(($size_ava-$size_db)) -lt 1048576 ]; then
        echo "Not enough disk space for copying db. Available space:  ` echo "scale=2;$size_ava/1024/1024" |bc`GB Necessary space:  ` echo "scale=2;($size_db/1024/1024) + 1"|bc`Gb "
        return 1
    fi
}
size_db()
{
    local export ORACLE_SID=$1
    local role=$2 #role=1 значит это стэндбай. И для него надо считать место без undo 
    local dbsz 
    if [[ $role -eq 1 ]];then
	dbsz=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<-\EOF
set verify off pagesize 0 feedback off
col sum for 999999999999999999999
select sum(bytes) sum from v$datafile vd,v$tablespace vt where vd.ts#=vt.ts# and not regexp_like (vt.name,'TEMP');
EOF
	)
    else
	dbsz=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<-\EOF
set verify off pagesize 0 feedback off
col sum for 999999999999999999999
select sum(bytes) sum from v$datafile vd,v$tablespace vt where vd.ts#=vt.ts# and not regexp_like (vt.name,'UNDO|TEMP');
EOF
	)
    fi
printf "%s" $dbsz
}
shut_db()
{
#trap 'trap_commands' ERR
#    [ -f "$CS" ] && . $CS
    local export ORACLE_SID=$1
    local DETAIL=$2
    if pgrep -fx ora_pmon_$ORACLE_SID >/dev/null ; then
        ver=$(sqlplus -s / as sysdba<<<"select ibs.inst_info.get_version from dual;" |sed -n 's/\.//gp;' | sed -n '/^[0-9]*$/p')
        echo -e "\nShut down $DETAIL database $ORACLE_SID"
        if  $ORACLE_HOME/bin/sqlplus -s "/ as sysdba" <<<"select controlfile_type from v\$database;" | grep -q STA ; then
            echo -e "\nShut down $DETAIL standby database $ORACLE_SID"
            $ORACLE_HOME/bin/sqlplus -s "/ as sysdba"  <<EOFsql
--WHENEVER SQLERROR EXIT SQL.SQLCODE
alter database recover managed standby database cancel;
shutdown immediate;
EOFsql
        else
            if [[ $ver -le 7310 ]] && [[ -n $ver ]]; then
                sqlplus -s / as sysdba <<EOFsql
--WHENEVER SQLERROR EXIT SQL.SQLCODE
exec ibs.rtl.lock_stop;
shutdown immediate;
exit
EOFsql
            else
                sqlplus -s  / as sysdba <<EOF
--WHENEVER SQLERROR EXIT SQL.SQLCODE
shutdown immediate;
EOF
            fi
        fi
    fi
#    if [ -f "$CS" ] && [ -n "$count_sid" ] ; then
#        . $CS
#        ((--count_sid))
#        echo "count_sid=$count_sid" > $CS
#    fi
}

#info_os()
#{
#    
#    [ -n "$flag_info_os" ] && return
#    
#
#    case $(uname) in
#        'Linux')
#            flagos=0
#            oratab=/etc/oratab
#            ;;
#        'SunOS')
#            flagos=1
#            oratab=/var/opt/oracle/oratab
#            ;;
#        'HP-UX')
#            flagos=3
#            oratab=/etc/oratab
#            unix="UNIX95="
#            ;;
#        *)
#            echo "OS $(uname) doesn't supported"
#            exit 1;
#            ;;
#    esac
#    flag_info_os=1
#}

find_dirdb()
{
    local DIR_DB
    DIR_DB=$($ORACLE_HOME/bin/sqlplus -s "/ as sysdba" <<-\EOF
set verify off head off feedback off pagesize 0 
whenever oserror exit oscode
whenever sqlerror exit sql.sqlcode
select regexp_substr(name,'.*oradata/[a-zA-Z0-9_#$]+',1,1,'i') from v$datafile where rownum=1;
quit;
EOF
          )
    if [ $? -eq 0 ]; then 
	printf "%s" $DIR_DB
    else
	printf "%s" 
    fi
}
find_oralist()
{
    local ORALIST 
    ORALIST=$($ORACLE_HOME/bin/sqlplus -s "/ as sysdba" <<-\EOF
set verify off head off feedback off pagesize 0
whenever sqlerror exit sql.sqlcode
select value from v$parameter where name='local_listener';
quit;
EOF
          )
    [ $? -eq 0 ] && printf "%s" $ORALIST || printf "%s"
}
envora()
{
    local SOURCE_SID=$1
    local PROFILE
    if ps -ef |  grep -w ora_pmon_$SOURCE_SID  &>/dev/null; then
        flag_stardb=0
        if grep "$SOURCE_SID" $oratab &>/dev/null; then
            export ORAENV_ASK=NO
            export ORACLE_SID=$SOURCE_SID
            . oraenv >/dev/null
        # else
        #     PROFILE=$(fnd_profile ora_pmon_$SOURCE_SID)
        #     [[ -z $PROFILE ]] && { echo "Can't find profile"; return 1;} 
        #     . $PROFILE
        #     export ORACLE_SID=$SOURCE_SID
        #     echo "PROFILE=$PROFILE"
        #     echo "ORACLE_SID=$ORACLE_SID"
        fi
    else
        flag_stardb=1
    fi
    unset TNS_ADMIN
}

status_db()
{
    local mode
    mode=$($ORACLE_HOME/bin/sqlplus -s "/ as sysdba" <<-\EOF
set verify off feedback off pagesize 0
whenever sqlerror exit sql.sqlcode
select open_mode from v$database;
EOF
    )
    
    if [ $? -eq 0 ]; then
	printf "%s" $mode
    else
	return 1;
    fi
}

check_startdb ()
{
    local SOURCE_SID=$1
    if pgrep -fx ora_pmon_$SOURCE_SID >/dev/null ; then
        return 0
    else
        return 1
    fi
}
check_conn_db()
{
    local connect=$1 #для доступа локально или удаленно к БД.
    local connect_str=$2
    local conn_out
    connect=${connect:-'local'}
    case $connect  in
        'local' )
            connect='-s /'
            ;;
        'remote' )
            connect="-s $connect_str"

            ;;
    esac
    conn_out=$($ORACLE_HOME/bin/sqlplus $connect as sysdba <<-\EOF
set feedback off pagesize 0
whenever sqlerror exit sql.sqlcode
select open_mode from v$database;
EOF
    )
if [ $? -ne 0 ]; then
    echo "$conn_out"
    return 1
else
    return 0
fi
}
check_ans()
{
    case ${yn} in
        # "yes", "y"
        [Yy][Ee][Ss]|[Yy])
        ;;
        # all other
        *)
            echo "User interrupted."
            exit 1
            ;;
    esac
    yn=""
}
stats()
{
    sqlplus -s '/ as sysdba' <<EOF >/dev/null
prompt########Gathering statistics#############;
EXEC DBMS_STATS.GATHER_SYSTEM_STATS ('NOWORKLOAD');
EXEC DBMS_STATS.GATHER_DICTIONARY_STATS();
EXEC DBMS_STATS.GATHER_FIXED_OBJECTS_STATS();
EXEC DBMS_STATS.GATHER_SCHEMA_STATS(ownname=>'IBS',degree=>DBMS_STATS.AUTO_DEGREE,METHOD_OPT=>'FOR ALL COLUMNS SIZE AUTO',CASCADE=>TRUE);
EOF
}

delvss()
{
    echo -n "Delete information about VSS: " 
    sqlplus -s '/ as sysdba' <<EOF >/dev/null
set pagesize 0 feedback off verify off
whenever oserror exit oscode                        
whenever sqlerror exit sql.sqlcode                  
col xxx new_value pass noprint
col xxx2 new_value spare4 noprint
select password xxx, spare4 xxx2 from user$ where name='IBS';
alter user ibs identified by ibs;
conn ibs/ibs
update settings set value='' where name like 'VSS%';
commit;                                             
conn / as sysdba
alter user ibs identified by values '&pass;&spare4' account unlock;
quit
EOF
    if [ $? -ne 0 ] ;then
	echo "WARNING"
    else
	echo "Success"
    fi
}
change_fio()
{
    #errors "warning"
    local FIO=$1
    local FIODIR=$(echo $FIO | perl -n -e 'print $1 if /(.*fio).*/')
    echo -n "Change parameters for fio: "
    sqlplus -s '/ as sysdba' <<-EOF >/dev/null
set feedback off verify off pagesize 0
whenever oserror exit oscode                        
whenever sqlerror exit sql.sqlcode                  
col xxx new_value pass noprint
col xxx2 new_value spare4 noprint
select password xxx, spare4 xxx2 from user$ where name='IBS';
alter user ibs identified by ibs;
conn ibs/ibs
alter session set nls_language='AMERICAN';
update ibs.profiles set value='${FIO}' where profile='DEFAULT' and resource_name='FIO_HOME_DIR';
update ibs.profiles set value='/ibs' where profile='DEFAULT' and resource_name='FIO_ROOT_DIR';
update ibs.profiles set value='/u/tools/fio_${ORACLE_SID}_ibs.log' where profile='DEFAULT' and resource_name='FIO_LOG_FILE';
update ibs.profiles set value='1' where profile='DEFAULT' and resource_name='FIO_DEBUG_LEVEL';
update ibs.profiles set value='/tmp' where profile='DEFAULT' and resource_name='FIO_TEMP_DIR';
commit;
conn / as sysdba
alter user ibs identified by values '&pass;&spare4' account unlock;
quit
EOF
    if [ $? -ne 0 ]; then
	echo "WARNING"
    else
	echo "Success"
    fi    
    echo -n "Create directory for FIO: "
    if [ -d $FIO/ibs ] || [ ! -w $FIODIR ]; then
        echo "WARNING    Directory $FIO already exists or write access denied "
    else
        mkdir -p $FIO/ibs
        echo "Success"
    fi
    }
check_fio()
{
    #errors "warning"
    echo -n "Check FIO,XML,CONTEXT for $ORACLE_SID: " 
    $ORACLE_HOME/bin/sqlplus -s '/ as sysdba' <<-\EOF >/dev/null
set feedback off verify off pagesize 0
whenever oserror exit oscode
whenever sqlerror exit sql.sqlcode
col xxx new_value pass noprint
col xxx2 new_value spare4 noprint
select password xxx, spare4 xxx2 from user$ where name='IBS';
alter user ibs identified by ibs;
conn ibs/ibs
alter session set nls_language='AMERICAN';
--Check FIO
exec stdio.fio_open;
whenever sqlerror continue
select stdio.file_list('.') from dual;
whenever sqlerror exit sql.sqlcode
--##########XML################
exec xrc_xmlparser.initialize();
--##########Context############
select sys_context('IBS_SYSTEM','USR') from dual;
select sys_context('IBS_SYSTEM','OWNER') from dual;
conn / as sysdba
alter user ibs identified by values '&pass;&spare4' account unlock;
quit
EOF
    if [ $? -ne 0 ]; then
	echo "WARNING"
    else
	echo "Success"
    fi
}

exectime ()
{
    let TIME_MIN=$SECONDS/60
    let SEC=$SECONDS%60
    let TIME_HOUR=$SECONDS/3600
    let TIME_MIN=$TIME_MIN%60
    echo "Executing time script $(basename $0) : $TIME_HOUR hour $TIME_MIN min $SEC sec"
}

cft_job_start()
{
    echo -n "CFT job Start: "
    sqlplus -s '/ as sysdba' <<-\EOF >/dev/null
set feedback off verify off pagesize 0
whenever oserror exit oscode
whenever sqlerror exit sql.sqlcode
col xxx new_value pass noprint
col xxx2 new_value spare4 noprint
select password xxx, spare4 xxx2 from user$ where name='IBS';
alter user ibs identified by ibs;
--prompt------Start audmgr----------;
exec audm.aud_mgr.stop;
exec dbms_lock.sleep(30);
alter trigger audm.logon_trigger compile;
exec audm.aud_mgr.get_settings(true);
exec audm.aud_mgr.submit;
conn ibs/ibs
DECLARE
i NUMBER;
BEGIN
i := ibs.executor.lock_open;
IBS.Z$SYSTEM_JOBS_STOP_SYS_JOBS.STOP_SYS_JOBS_EXECUTE(
        THIS=>NULL,
        PLP$CLASS=>'SYSTEM_JOBS',
        P_JOB_SES=>FALSE,
        P_LOCK_USERS=>FALSE,
        P_SEC_JOB=>FALSE,
        P_RPT_RIGHTS=>FALSE,
        P_JOB_LIC=>TRUE,
        P_CACHE_PIPES=>TRUE,
        P_SEQ_JOB=>TRUE,
        P_LOCK_REFRESH=>TRUE,
        P_ORSA_CLEAR=>TRUE,
        P_LOCK_RUN=>TRUE,
        P_LOCK_STOP=>FALSE);
IBS.Z$SYSTEM_JOBS_SUBMIT_SYS_JOBS.SUBMIT_SYS_JOBS_EXECUTE(
        THIS=>NULL,
        PLP$CLASS=>'SYSTEM_JOBS',
        P_JOB_SES=>FALSE,
        P_LOCK_USERS=>FALSE,
        P_JOB_SES_PER=>NULL,
        P_RUN_LOCKS=>NULL,
        P_LOCK_PIPE=>NULL,
        P_SEC_JOB=>FALSE,
        P_RPT_RIGHTS=>FALSE,
        P_SEC_PERIOD=>NULL,
        P_RPT_START=>NULL,
        P_CLEAR_RIGHTS=>FALSE,
        P_JOB_LIC=>TRUE,
        P_JOB_LIC_START=>TO_DATE('03:00:00','HH24:MI:SS'),
        P_CACHE_PIPES=>TRUE,
        P_CACHE_PERIOD=>300,
        P_SEQ_JOB=>TRUE,
        P_SEQ_PERIOD=>360,
        P_LOCK_REFRESH=>TRUE,
        P_REFRESH_PERIOD=>10,
        P_ORSA_CLEAR=>TRUE,
        P_ORSA_START=>TO_DATE('04:00:00','HH24:MI:SS'),
        P_LOCK_RUN=>TRUE,
        P_LOCK_START=>TO_DATE('06:00:00','HH24:MI:SS'),
        P_LOCK_STOP=>FALSE,
        P_LOCK_RESTART=>NULL);
commit;
END;
/
conn / as sysdba
alter user ibs identified by values '&pass;&spare4' account unlock;
quit;
EOF
   if [ $? -eq 0 ]; then
       echo "Success"
   else
       echo "WARNING"
   fi
}
deljobs()
{
    echo -n "Delete jobs: " 
    sqlplus -s '/as sysdba' <<-\EOF
set feedback off verify off pagesize 0     
whenever oserror exit oscode
whenever sqlerror exit sql.sqlcode
begin
audm.aud_mgr.stop;
dbms_lock.sleep(60);
   for c in ( select job from dba_jobs )
   loop
     begin
        dbms_ijob.remove(c.job);
     end;
   end loop;
end;
/
commit;
EOF
    echo "Success" 
}


trap_main()
{
    local line_no=$1
    local err_status=$2 
#    exit 1
    if [ "$err_status" == "critical" ]; then
	local scriptpath="$(cd $(dirname $0); pwd -P)/$(basename $0)"
	local errstring="$(date +'%d.%m.%y %H:%M:%S') Script $scriptpath finished with Critical error! \n$err \nCause of error on line $line_no :\n $BASH_COMMAND"
	echo -e "$errstring"
	[ -n "$mailsend" ] && echo -e "$errstring" | mailx -s "$mailtext" "$mailsend"
	exit 1
    fi
    [ "$err_status" == "warning" ] && echo "WARNING"
}

#-------------------------
trap_com() {
    local line_no=$1
    local err_status=$2
    trap_main $line_no $err_status
}
#-------------------------

errors()
{
    local err_status=$1
    trap "trap_com $LINENO $err_status" ERR
}


grantsexp()
{
   echo -n "Grants to EXPDB user: " 
   sqlplus -s / as sysdba <<-EOF
set feedback off verify off pagesize 0
whenever oserror exit oscode                   
whenever sqlerror exit sql.sqlcode
drop user EXPDB cascade;
create user EXPDB identified by termite_$ORACLE_SID;
alter user EXPDB identified by termite_$ORACLE_SID DEFAULT TABLESPACE t_usr TEMPORARY TABLESPACE temp;
GRANT CONNECT,RESOURCE,UNLIMITED TABLESPACE to EXPDB;
grant EXP_FULL_DATABASE to EXPDB;
GRANT EXECUTE ON SYS.DBMS_DEFER_IMPORT_INTERNAL TO EXPDB;
GRANT EXECUTE ON SYS.DBMS_EXPORT_EXTENSION TO EXPDB;
GRANT EXECUTE ON SYS.DBMS_JVM_EXP_PERMS TO EXPDB;
grant FLASHBACK ANY TABLE to DATAPUMP_EXP_FULL_DATABASE;
grant become user to DATAPUMP_EXP_FULL_DATABASE;
grant DATAPUMP_EXP_FULL_DATABASE to EXPDB;
create or replace directory EXPDP as '/u/app/export/$ORACLE_SID';
grant READ,WRITE on directory EXPDP to EXPDB;
EOF
   if [ $? -ne 0 ]; then
       echo "WARNING"
   else
       echo "Success"
   fi 
}

export_dp()
{
    local ORACLE_SID=$1
    [ -z $(tail -c1 /u/app/export/bin/expdp.cfg) ]; echo -n -e "\n"  >> /u/app/export/bin/expdp.cfg
    echo "$ORACLE_SID:$ORACLE_HOME:expdb:termite_$ORACLE_SID:ALL:/u/app/export/$ORACLE_SID" >> /u/app/export/bin/expdp.cfg
    [ ! -d /u/app/export/$ORACLE_SID ] && mkdir /u/app/export/$ORACLE_SID
    [ ! -L /u/app/export/$ORACLE_SID/after.sh ] && ln -s /u/app/export/bin/after.sh /u/app/export/$ORACLE_SID/after.sh
    [ ! -L /u/app/export/$ORACLE_SID/before.sh ] && ln -s /u/app/export/bin/before.sh /u/app/export/$ORACLE_SID/before.sh
    if ! crontab -l | grep expdp &>/dev/null ; then
        echo -e "\nConfigure export with DATAPUMP: ERROR   The run-expdp.sh does not found in cron\n"
    fi
    
}

oracle_ver()
{
    VERSION=$(
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<-\QWE
set pagesize 0 feedback off
select version from v$instance;
QWE
)
    VER=$(echo $VERSION | awk -F"." '{print $1}')
    SUBVER=$(echo $VERSION | awk -F"." '{print $4}')
}

reset_pass()
{
    local arrusers=(${1//,/ })
    for user in ${arrusers[@]}
    do	
	usr=${user%/*}
	pass=${user#*/}
	pass=${pass:-$usr}
	echo -n "Reset password for user $usr: "
	
	$ORACLE_HOME/bin/sqlplus -s '/ as sysdba' <<EOF
set feedback off verify off pagesize 0
whenever oserror exit oscode                        
whenever sqlerror exit sql.sqlcode                  
alter user $usr identified by $pass account unlock;
EOF
	if [ $? -ne 0 ];then
	    echo "WARNING"
	else
	    echo "Success"
	fi
    done
}
reset_user_pass()
{
    local USR=$1
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<-EOF
     set serveroutput on feedback off verify off;
 DECLARE
    pass_tbl varchar2(50):='OLD_USER_PASS';
    tbl_owner dba_objects.owner%type;
    cpt number:=0;
    usr dba_users.username%type:=upper('$USR');
    dft_pass varchar2(10):='ibs';
 BEGIN
    select username into usr from dba_users where username=usr;
    begin
         select owner into tbl_owner from dba_objects where object_name=pass_tbl;
    exception
       WHEN no_data_found THEN
          tbl_owner:='SYS';
          dbms_output.put_line('create table '||tbl_owner||'.'||pass_tbl||'(name varchar2(128),spare4 varchar2(1000),password varchar2(30))');
          execute immediate 'create table '||tbl_owner||'.'||pass_tbl||'(name varchar2(128),spare4 varchar2(1000),password varchar2(30))';
    end;
    execute immediate 'select count(*) from '||tbl_owner||'.'||pass_tbl||' where name='''||usr||''' '
        into cpt;
    if cpt = 1 then
       dbms_output.put_line('delete from '||tbl_owner||'.'||pass_tbl||' where name='''||usr||''';');
       execute immediate 'delete from '||tbl_owner||'.'||pass_tbl||' where name='''||usr||'''';
    end if;
    dbms_output.put_line('insert into '||tbl_owner||'.'||pass_tbl||' select name,spare4,password from sys.user\$ where name='''||usr||''';');
    execute immediate 'insert into '||tbl_owner||'.'||pass_tbl||' select name,spare4,password from sys.user\$ where name='''||usr||'''';
    dbms_output.put_line('alter user '||usr||' identified by '||dft_pass);
    execute immediate 'alter user '||usr||' identified by '||dft_pass;
 exception
    WHEN no_data_found THEN
       dbms_output.put_line('User:'||usr||' not found in database');
 END;
/
commit;
quit;
EOF
}
return_user_pass()
{
    local USR=$1
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<-EOF
     set serveroutput on feedback off verify off
 DECLARE
    pass_tbl varchar2(50):='OLD_USER_PASS';
    tbl_owner dba_objects.owner%type;
    usr dba_users.username%type:=upper('$USR');
    type user_pass_list is record (name user\$.name%type,
                                   spare4 user\$.spare4%type,
                                   password user\$.password%type);
    user_pass user_pass_list;
 BEGIN
    begin
         select owner into tbl_owner from dba_tables where table_name=pass_tbl;
    exception
       WHEN no_data_found then
          dbms_output.put_line('Table not found');
          return 1;
    end;
    execute immediate 'select name,spare4,password from '||tbl_owner||'.'||pass_tbl||' where name='''||usr||'''' into user_pass;
    dbms_output.put_line(user_pass.name);
    dbms_output.put_line('ALTER USER '||user_pass.name||'  IDENTIFIED BY VALUES '''||user_pass.spare4||';'||user_pass.password||'''');
    execute immediate 'ALTER USER '||user_pass.name||'  IDENTIFIED BY VALUES '''||user_pass.spare4||';'||user_pass.password||'''';
    dbms_output.put_line('drop table '||tbl_owner||'.'||pass_tbl);
    execute immediate 'drop table '||tbl_owner||'.'||pass_tbl;
 EXCEPTION
       WHEN no_data_found THEN
 dbms_output.put_line('No entries for '||usr);
 END;
/
quit;
EOF
}
recreate_undo()
{
#    errors "warning"
$ORACLE_HOME/bin/sqlplus -s / as sysdba <<-\EOF
   set serveroutput on
   DECLARE
   TS_UNDO DBA_TABLESPACES.TABLESPACE_NAME%TYPE;
   CNT pls_integer;
   UNDO_FILE_DATA DBA_DATA_FILES.FILE_NAME%TYPE;
   FILE_DATA DBA_DATA_FILES.FILE_NAME%TYPE;
   TS_UNDO_TMP constant varchar2(20):='undotmp';
BEGIN
     SELECT TABLESPACE_NAME INTO TS_UNDO FROM DBA_TABLESPACES WHERE CONTENTS='UNDO';
     SELECT NVL2(VALUE,1,0) INTO CNT FROM V$PARAMETER WHERE NAME='db_create_file_dest';
--dbms_output.put_line(CNT||' '||TS_UNDO);
   IF CNT=0 THEN
        SELECT FILE_NAME INTO UNDO_FILE_DATA FROM DBA_DATA_FILES WHERE TABLESPACE_NAME = TS_UNDO;
        SELECT REGEXP_REPLACE(FILE_NAME,'[a-zA-Z0-9_]+\.dbf','undotmp.dbf') INTO FILE_DATA FROM DBA_DATA_FILES WHERE TABLESPACE_NAME = TS_UNDO;
      EXECUTE IMMEDIATE 'CREATE UNDO TABLESPACE '||TS_UNDO_TMP||' datafile '''||FILE_DATA||''' size 250M AUTOEXTEND ON NEXT 5120K MAXSIZE UNLIMITED';
      EXECUTE IMMEDIATE 'ALTER SYSTEM SET UNDO_TABLESPACE='||TS_UNDO_TMP;
      EXECUTE IMMEDIATE 'DROP TABLESPACE '||TS_UNDO||' INCLUDING CONTENTS AND DATAFILES';
      EXECUTE IMMEDIATE 'CREATE UNDO TABLESPACE '||TS_UNDO||' datafile '''||UNDO_FILE_DATA||'''  size 250M AUTOEXTEND ON NEXT 5120K MAXSIZE UNLIMITED';
   ELSE
      EXECUTE IMMEDIATE 'CREATE UNDO TABLESPACE '||TS_UNDO_TMP||' DATAFILE SIZE 250M AUTOEXTEND ON NEXT 5120K MAXSIZE UNLIMITED';
      EXECUTE IMMEDIATE 'ALTER SYSTEM SET UNDO_TABLESPACE='||TS_UNDO_TMP;
      EXECUTE IMMEDIATE 'DROP TABLESPACE '||TS_UNDO||' INCLUDING CONTENTS AND DATAFILES';
      EXECUTE IMMEDIATE 'CREATE UNDO TABLESPACE '||TS_UNDO||' DATAFILE SIZE 250M AUTOEXTEND ON NEXT 5120K MAXSIZE UNLIMITED';
   END IF;
   EXECUTE IMMEDIATE 'ALTER SYSTEM SET UNDO_TABLESPACE='||TS_UNDO;
   EXECUTE IMMEDIATE 'DROP TABLESPACE '||TS_UNDO_TMP||' INCLUDING CONTENTS AND DATAFILES';
   DBMS_OUTPUT.PUT_LINE('Recreating tablespace UNDO: Success');
EXCEPTION
   WHEN NO_DATA_FOUND THEN
      DBMS_OUTPUT.PUT_LINE('Recreating tablespace UNDO: ERROR  TS UNDO not found');
END;
EOF
}
copy_fio()
{
    local xargs_flag=""
    [[ "$flagos" -eq 0 ]] && xargs_flag="-r" #Команда для Linux
    #errors "warning"
    echo -n "Copy fio: "
    local SRC_FIO=$1
    local DST_FIO=$2
    if [ -d "$SRC_FIO" -a -w "$DST_FIO" ]; then
	find $DST_FIO -type d -perm -1000 |  xargs $xargs_flag -n 1 chmod -t
	rsync -a --delete "${SRC_FIO}/" $DST_FIO
    else
	echo "WARNING  Source FIO directory $SFIO doesn't exists or write access denied"
	#return 1
    fi
    
    echo "Success"
    
}
export_dp()
{
    #errors "warning"
    local ORACLE_SID=$1
    echo -ne "Configure export with DATAPUMP: " 
    [ -z $(tail -c1 /u/app/export/bin/expdp.cfg) ]; echo -n -e "\n"  >> /u/app/export/bin/expdp.cfg
    echo "$ORACLE_SID:$ORACLE_HOME:expdb:termite_$ORACLE_SID:ALL:/u/app/export/$ORACLE_SID" >> /u/app/export/bin/expdp.cfg
    [ ! -d /u/app/export/$ORACLE_SID ] && mkdir /u/app/export/$ORACLE_SID
    [ ! -L /u/app/export/$ORACLE_SID/after.sh ] && ln -s /u/app/export/bin/after.sh /u/app/export/$ORACLE_SID/after.sh
    [ ! -L /u/app/export/$ORACLE_SID/before.sh ] && ln -s /u/app/export/bin/before.sh /u/app/export/$ORACLE_SID/before.sh
    if ! crontab -l | grep expdp &>/dev/null ; then
        echo  "WARNING    Check cron. The run-expdp.sh does not found in cron\n"
    fi
    echo "Success" 
}

dbnewid()
{
    local export ORACLE_SID=$1
    shut_db $ORACLE_SID
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
startup mount;
quit;
EOF
    $ORACLE_HOME/bin/nid target=/<<<y
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
startup mount;
alter database open resetlogs;
quit;
EOF
}
oracle_info()
{
    #ORACLE_HOME уже определен.   
    local PAR
    local connect=$1 #для доступа локально или удаленно к БД.
    local connect_str=$2
    connect=${connect:-'local'}
    case $connect  in 
        'local' )
            connect='-s /'
            ;;
        'remote' )
            connect="-s $connect_str"
            
            ;;
    esac    
     PAR=($($ORACLE_HOME/bin/sqlplus $connect as sysdba <<-\EOF
     set serveroutput on feedback off
 DECLARE
    ver v$instance.version%type;
    TYPE list_of_parameters IS TABLE OF v$parameter.value%TYPE INDEX BY varchar2(20);
parameters list_of_parameters;
owner varchar2(10);
--l_row PLS_INTEGER;
e_noTblFound EXCEPTION;
e_notOpen EXCEPTION;
PRAGMA exception_init(e_noTblFound, -942);
PRAGMA exception_init(e_notOpen, -1219);
fio varchar2(100);
cIndex varchar2(20);
dirdb varchar2(100);
edition varchar2(20);
vdat v$database%ROWTYPE;
bct v$block_change_tracking%ROWTYPE;
BEGIN
     select version into ver from v$instance;
     select nvl(regexp_substr(banner,'^.* (\w+ Edition)',1,1,'i',1),'Standard Edition') into edition from v$version where banner like 'Oracle Database%';
   FOR par IN (SELECT name,NVL(value,'NONE') as value from v$parameter where lower(name) in ('compatible','local_listener','job_queue_processes','spfile','db_create_file_dest'))
   LOOP
      parameters(par.name) := par.value;
   END LOOP;
     SELECT * INTO vdat from v$database;
   BEGIN
      EXECUTE IMMEDIATE 'SELECT value from audm.settings where name=''OWNERS''' into owner;
   EXCEPTION
      WHEN e_notOpen or e_noTblFound THEN
         owner := 'IBS';
   END;
   BEGIN
      EXECUTE IMMEDIATE 'select value from ibs.profiles where resource_name=''FIO_HOME_DIR'' and profile=''DEFAULT''' INTO fio;
   EXCEPTION
      WHEN e_noTblFound or e_notOpen THEN
         fio := 'NONE';
   END;
   SELECT * into bct from V$BLOCK_CHANGE_TRACKING;
   SELECT REGEXP_SUBSTR(name,'.*oradata/[a-zA-Z0-9_#$]+',1,1,'i') INTO dirdb FROM v$datafile WHERE rownum=1;
   dbms_output.put_line('sid:'||sys_context('userenv','instance_name'));
   DBMS_OUTPUT.put_line('version:'||ver);
   IF edition = 'Standard Edition' THEN
      DBMS_OUTPUT.put_line('edition:SE');
   ELSE
      DBMS_OUTPUT.put_line('edition:EE');
   END IF;
   DBMS_OUTPUT.put_line('database_role:'||REGEXP_SUBSTR(vdat.database_role,'(standby|primary)',1,1,'i'));
   DBMS_OUTPUT.put_line('log_mode:'||vdat.log_mode);
   CASE vdat.open_mode 
      WHEN 'READ WRITE' THEN DBMS_OUTPUT.put_line('open_mode:R/W');
      WHEN 'READ ONLY' THEN DBMS_OUTPUT.put_line('open_mode:R/O');
   ELSE
      DBMS_OUTPUT.put_line('open_mode:'||vdat.open_mode);
   END CASE;
   DBMS_OUTPUT.put_line('dirdb:'||dirdb);
   cIndex := parameters.FIRST;
   WHILE cIndex IS NOT NULL
      LOOP
      DBMS_OUTPUT.put_line(cIndex||':'||parameters(cIndex));
      cIndex := parameters.NEXT(cIndex);
   END LOOP;
   DBMS_OUTPUT.put_line('owner:'||owner);
   DBMS_OUTPUT.put_line('fio:'||fio);
   IF bct.STATUS = 'ENABLED' THEN
      DBMS_OUTPUT.put_line('bct:'||bct.filename);
   END IF;
END;
/
EOF
             ))
     echo ${PAR[@]}
}
parse_oracle_info()
{
    local param_name=$1
    shift
    local array_param=($@)
    echo ${array_param[@]} | perl -ne 'print $1 if /'"$param_name"':(\S+)\s?/i'
}
create_spfile()
{
    local SID=$1
    local spfile=$ORACLE_HOME/dbs/spfile${SID}.ora
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<-EOF
     set serveroutput on feedback off
 DECLARE
    spfile varchar2(100);
 BEGIN
      SELECT nvl(value,'NONE') INTO spfile from v\$parameter where lower(name)='spfile';
    IF spfile = 'NONE' THEN
       EXECUTE IMMEDIATE 'create spfile from pfile';
       EXECUTE IMMEDIATE q'{alter system set spfile='$spfile'}';
       DBMS_OUTPUT.put_line(q'{Execute: alter system set spfile='$spfile';}');
       DBMS_OUTPUT.put_line('Create spfile from pfile: Success');
    ELSE
       DBMS_OUTPUT.put_line('Create spfile from pfile: Spfile has been already  used');
    END IF;
 END;
/
EOF
    if [ -f $spfile ]; then
        [ -f ~/admin/$SID/pfile/init${SID}.ora ] && mv ~/admin/$SID/pfile/init${SID}.ora ~/admin/$SID/pfile/init${SID}.ora.spfile
        [ -L $ORACLE_HOME/dbs/init${SID}.ora ] && rm $ORACLE_HOME/dbs/init${SID}.ora
    fi
    
}
oratab_entry()
{
    local sid=$1
    local orcl_home=$2
    local oratab=$3   
    local oratab_tmp=/u/app/oracle/oratab
    local ORA_STRING
    
    [ -f $oratab_tmp ] && rm -f /u/app/oracle/oratab
    cp $oratab $oratab_tmp
    echo -e "\n\n#####Not in NSD CMDB############" >> $oratab_tmp
    ORA_STRING="$sid:$orcl_home:N"
    echo "$ORA_STRING" >> $oratab_tmp
    cp $oratab_tmp $oratab
}
lis_stat_reg ()
{
    local ORACLE_SID=$1
    ORALIST=$(perl -n -e 'print $1 if /(^ORALIST[0-9]+(?:se)?)[ =]/i' $ORACLE_HOME/network/admin/listener.ora)
    ORALIST_UP=$(echo $ORALIST | tr '[a-z]' '[A-Z]')
    ORALIST=$ORALIST_UP

    echo "Listener=$ORALIST"

    if ! grep -i $ORACLE_SID $ORACLE_HOME/network/admin/listener.ora  &>/dev/null; then
        echo "static registrarion"
                perl -n -i -e '                                                                                     
    print;                                                                                                  
    if (/^SID_LIST_'$ORALIST'\s+=/i) {                                                                      
    $_ = <>;                                                                                                
    print;                                                                                                  
    print "      (SID_DESC =\n" .                                                                           
          "         (SID_NAME = '$ORACLE_SID')\n" .                                                         
          "         (ORACLE_HOME = '$ORACLE_HOME')\n" .                                                     
          "      )\n";                                                                                      
        $flag=1;                                                                                            
    }                                                                                                       
    print "SID_LIST_'$ORALIST' =\n" .                                                                       
          "  (SID_LIST =\n" .                                                                               
          "      (SID_DESC =\n" .                                                                           
          "         (SID_NAME = '$ORACLE_SID')\n" .                                                         
          "         (ORACLE_HOME = '$ORACLE_HOME')\n" .                                                     
          "      )\n" .                                                                                     
          "  )\n" if eof and ! $flag;                                                                       
' $ORACLE_HOME/network/admin/listener.ora
                lsnrctl reload $ORALIST
    fi


}                                                                                                           
drop_db()
{
    local export ORACLE_SID=$1
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE;
STARTUP FORCE MOUNT;
ALTER SYSTEM ENABLE RESTRICTED SESSION;
DROP DATABASE;
EOF
    if [ $? -ne 0 ]; then
	echo "Error when DROP DATABASE $ORACLE_SID"
	return 1
    else
	return 0
    fi
}
f_grant_rs()
{
local owner=$1
local grant_rs
grant_rs=$(sqlplus -s '/ as sysdba' <<-\EOF
set pagesize 0 feedback off serveroutput on                                                            
DECLARE                                                                                                
  grs dba_sys_privs.privilege%type;                                                                    
BEGIN                                                                                                  
  select privilege into grs from dba_sys_privs where grantee='$owner' and privilege='RESTRICTED SESSION'; 
  IF grs = 'RESTRICTED SESSION' then                                                                   
    DBMS_OUTPUT.PUT_LINE('NOREVOKE');                                                                  
  END IF;                                                                                              
EXCEPTION                                                                                              
  WHEN no_data_found then                                                                              
  execute immediate 'GRANT RESTRICTED SESSION to IBS';                                                 
  DBMS_LOCK.SLEEP(5);                                                                                  
  DBMS_OUTPUT.PUT_LINE('REVOKE');                                                                      
END;                                                                                                   
/                                                                                                      
EOF
)             
printf "%s" $grant_rs
}
protection_disable()
{
    echo "Disable protection: Start" 
    sqlplus -s / as sysdba <<-EOF
set feedback off verify off pagesize 0
whenever oserror exit oscode
whenever sqlerror exit sql.sqlcode
col xxx new_value pass noprint
col xxx2 new_value spare4 noprint
select password xxx, spare4 xxx2 from user$ where name='IBS';
alter user ibs identified by ibs;
conn ibs/ibs
@$DIRSQL/protection_disable.sql
conn / as sysdba
alter user ibs identified by values '&pass;&spare4' account unlock;
quit;
EOF
    if [ $? -ne 0 ]; then
	echo "Disable Protection : WARNING"
    else
	echo "Disable Protection : SUCCESS"
    fi
}
date_format()
{
    local dt=$1
    echo $dt | perl -MTime::Local=timelocal -Wne '
my $day31=qr#(?:0?[1-9]|[12]\d|3[01])#;
my $day30=qr#(?:0?[1-9]|[12]\d|30)#;
my $day29=qr#(?:0?[1-9]|[12]\d)#;
my $month_31d=qr#(?:0?[13578]|1[02])#;
my $month_30d=qr#(?:0?[469]|11)#;
my $year=qr#\d{4}#;
my $hour=qr#(?:[01]?\d|2[0-4])#;
my $min=qr#[0-5]\d#;
my $sec=qr#[0-5]\d#;
if (/^(
  (?:
    ($day31)\.($month_31d)|
    ($day29)\.(0?2)|
    ($day30)\.($month_30d)
  )
  \.($year)
  \ ($hour):($min):($sec)
)$/x) {
    if (defined $4) {
        die "incorrect date: $8 is not a leap year" if (! (($8 % 4 == 0 and $8 % 100 != 0) or $8 % 400 == 0)) and $4 == 29;
    }
    die "incorrect date, Doc!" if timelocal($11,
                                            $10,
                                            $9,
                                            defined $6 ? $6 : do { defined $4 ? $4 : $2; },
                                            defined $7 ? $7 - 1 : do { defined $5 ? $5 - 1 : $3 - 1; },
                                            $8) > time;
    print;
} else {
    die "incorrect date format";
}'
    return $?
}
