#!/usr/bin/python 
# -*- coding: utf-8 -*-
#
DOCUMENTATION = '''
---
module: oracle_db
short_description: Shutdown or startup database

version_added: "1.0"
options:
    sid:
        description
          - sid of database
        required: true
    cmd:
        description
          - shutdoen or startup database
        required true    
    mode:
        description:
          - various modes for startup
        required: true
        default: open
notes:
     - cx_Oracle needs to be installed
requirements: ["cx_Oracle"]
author: Evgeniy Krasnukhin, e.krasnukhin@gmail.com
'''

EXAMPLES ='''
- oracle_db:
    sid: "orasid"
    cmd: "startup"
    mode: "open"
'''


from ansible.module_utils.basic import AnsibleModule
from oracledb.dbexceptions import DbException
import oracledb.db


def main():
    module = AnsibleModule(
        argument_spec=dict(
            sid=dict(required=True),
            cmd=dict(required=True, choices=["startup","shutdown"]),
            mode=dict(required=True, choices=["nomount","mount","open","immediate","abort"])
        )
    )

    sid = module.params["sid"]
    cmd = module.params["cmd"]
    mode = module.params["mode"]

    try:
        db1 = oracledb.db.LocalDb(sid)
        if cmd == 'startup':
            getattr(db1, mode)()
        else:
            if mode == 'immediate':
                db1.shut_immediate()
            else:
                db1.shut_abort()

    except DbException, e:
        module.fail_json(msg=e.message, changed=False)
    
    module.exit_json(msg=mode, changed=True)

if __name__  == '__main__':
    main()
    
