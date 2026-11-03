"""Select a signing identity only after certificate revocation checking.

find-identity -v checks local validity; it can still list a revoked certificate.
Only public certificates are read. Private keys remain in the Keychain.
"""
import hashlib
from pathlib import Path
import re
import ssl
import subprocess
import tempfile


def first_trusted_identity(identities, certificates, verify, requested=None):
    if requested == '-':
        return '-'
    if requested is not None:
        candidates = [identity for identity in identities if identity == requested.upper()]
        if not candidates:
            raise RuntimeError('FRIDAY_COMPANION_SIGN_IDENTITY must be a known certificate SHA-1 or "-".')
    else:
        candidates = identities
    if not candidates:
        return '-'
    for identity in candidates:
        if identity in certificates and verify(certificates[identity]):
            return identity
    raise RuntimeError('No trusted signing certificate is available. Refresh the development certificate in Xcode; revoked certificates are not used.')


def verify_certificate(data):
    with tempfile.TemporaryDirectory(prefix='friday-public-cert-') as temp:
        certificate = Path(temp) / 'leaf.der'
        certificate.write_bytes(data)
        result = subprocess.run(['security', 'verify-cert', '-c', str(certificate),
                                 '-p', 'codeSign', '-R', 'ocsp', '-R', 'require'],
                                capture_output=True)
        return result.returncode == 0


def select_identity(requested=None):
    output = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                            capture_output=True, text=True, check=True).stdout
    identities = re.findall(r'\b([0-9A-F]{40})\s+"(?:Apple Development|Developer ID Application):[^\n]+"', output)
    certificates = {}
    for name in ['Apple Development', 'Developer ID Application']:
        result = subprocess.run(['security', 'find-certificate', '-a', '-p', '-c', name],
                                capture_output=True, text=True)
        for pem in re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', result.stdout, re.S):
            data = ssl.PEM_cert_to_DER_cert(pem)
            certificates[hashlib.sha1(data).hexdigest().upper()] = data
    return first_trusted_identity(identities, certificates, verify_certificate, requested)


def verify_signed_certificate(app):
    with tempfile.TemporaryDirectory(prefix='friday-signature-cert-') as temp:
        prefix = str(Path(temp) / 'cert')
        subprocess.run(['codesign', '-d', '--extract-certificates=' + prefix, str(app)],
                       capture_output=True, check=True)
        leaf = Path(prefix + '0')
        if not leaf.exists() or not verify_certificate(leaf.read_bytes()):
            raise RuntimeError('The resulting app has no trusted, non-revoked signing certificate.')
