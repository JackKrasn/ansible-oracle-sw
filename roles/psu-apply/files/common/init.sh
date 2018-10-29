#!/usr/bin/env bash
DIRSCR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DIRSQL=$DIRSCR/sql
COMDIR=$DIRSCR/common

ORA_ADMIN=/u/app/oracle/admin
ORA_EXPORT=/u/app/export
ORA_DATA1=/db1/oradata
XARGS=xargs
case $(uname) in
    'Linux')
        flagos=0
        oratab=/etc/oratab
        if [ -f /etc/SuSE-release ]; then
            os_info=`uname -a;cat /etc/SuSE-release`
        elif [ -f /etc/oracle-release ]; then
            os_info=`uname -a;cat /etc/oracle-release`
        else
            os_info=`uname -a`
        fi
	cmd_find=find        
        ;;
    'SunOS')
        flagos=1
        oratab=/var/opt/oracle/oratab
        os_info=$(uname -a;cat /etc/release)
	cmd_find=gfind
        XARGS=gxargs
        ;;
    'HP-UX')
            flagos=3
            oratab=/etc/oratab
            unix="UNIX95="
            os_info=$(uname -a;swlist -l bundle QPKBASE)
	    cmd_find=find
            ;;
    *)
        echo "OS $(uname) doesn't supported"
        exit 1;
        ;;
esac
