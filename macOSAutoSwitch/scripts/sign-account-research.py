#!/usr/bin/env python3
"""Use an existing developer identity so ordinary rebuilds keep a stable identity.

Does not create/export certificates or change Keychain item access permissions.
"""
import os
import re
import subprocess
import sys

identity = os.environ.get('BUDS_ACCOUNT_SIGNING_IDENTITY')
if identity is None:
    result = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                            check=True, capture_output=True, text=True)
    rows = re.findall(r'\) ([A-F0-9]{40}) "([^"]+)"', result.stdout)
    matches = [key for key, name in rows if name.startswith('Apple Development:')]
    if not matches:
        matches = [key for key, name in rows if name.startswith('Developer ID Application:')]
    if len(matches) > 1:
        raise SystemExit('Select BUDS_ACCOUNT_SIGNING_IDENTITY explicitly; multiple identities are available.')
    identity = matches[0] if matches else '-'
subprocess.run(['codesign', '--force', '--sign', identity, '--timestamp=none', sys.argv[1]], check=True)
subprocess.run(['codesign', '--verify', '--strict', sys.argv[1]], check=True)
print('Research app signed with ' + ('ad-hoc identity' if identity == '-' else 'existing developer identity'))
