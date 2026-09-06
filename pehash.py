#!/usr/bin/env python3
"""authenticode sha-256 of a PE image -- the digest UEFI matches against dbx.

this is NOT sha256sum of the file. the firmware hashes the image with three
regions excluded: the header checksum, the certificate-table directory entry,
and the attached signature itself. hashing the whole file instead produces a
number that never matches anything, and a dbx entry that silently revokes
nothing -- which looks exactly like a dbx entry that works.

two independent checks keep this honest, because a wrong hash here fails open:
  G21  the digest this computes must equal the one inside the image's own
       PKCS#7 signature (sbsign signed that digest, so it is ground truth)
  A11  a revoked image must actually be refused by the firmware, in a vm
"""
import hashlib
import struct
import sys


def _regions(b):
    """(spans_to_hash, cert_offset, cert_size) per the authenticode spec."""
    if len(b) < 0x40:
        raise ValueError("too short to be a PE image")
    if b[:2] != b"MZ":
        raise ValueError("not a PE image (no MZ)")
    pe = struct.unpack_from("<I", b, 0x3C)[0]
    if b[pe:pe + 4] != b"PE\0\0":
        raise ValueError("not a PE image (no PE signature)")
    # every unpack below reaches to at least pe+24+112+40; check once here so a
    # truncated image gets a diagnosis instead of a struct.error traceback.
    if pe + 24 + 176 > len(b):
        raise ValueError("truncated PE header")

    nsections = struct.unpack_from("<H", b, pe + 6)[0]
    opt_size = struct.unpack_from("<H", b, pe + 20)[0]
    opt = pe + 24
    magic = struct.unpack_from("<H", b, opt)[0]
    if magic == 0x10B:      # PE32
        dd = opt + 96
    elif magic == 0x20B:    # PE32+
        dd = opt + 112
    else:
        raise ValueError("unknown optional header magic 0x%x" % magic)

    checksum = opt + 64
    cert_dd = dd + 4 * 8                      # data directory entry 4
    size_of_headers = struct.unpack_from("<I", b, opt + 60)[0]
    cert_off, cert_size = struct.unpack_from("<II", b, cert_dd)
    # the certificate table is excluded from the hash, so its declared size
    # decides how much of the file IS hashed -- and it was taken on faith. an
    # inflated cert_size silently drops real content out of the digest, and a
    # size past the end made `tail` negative, at which point the guard below
    # dropped the trailing span entirely rather than complaining. three
    # different digests for one file, all exit 0. authenticode puts the table
    # at the very end, so demand exactly that.
    if cert_size:
        if cert_off < size_of_headers or cert_off + cert_size != len(b):
            raise ValueError(
                "certificate table (off %d size %d) is not the tail of the "
                "%d-byte file" % (cert_off, cert_size, len(b)))
    elif cert_off:
        raise ValueError("certificate table offset set with zero size")

    # headers, with the checksum and the cert-table entry cut out
    spans = [(0, checksum),
             (checksum + 4, cert_dd),
             (cert_dd + 8, size_of_headers)]

    # sections in file order, exactly SizeOfRawData bytes each
    sec = opt + opt_size
    secs = []
    for i in range(nsections):
        h = sec + i * 40
        raw_size, raw_ptr = struct.unpack_from("<II", b, h + 16)
        if raw_size:
            secs.append((raw_ptr, raw_size))
    secs.sort()
    hashed = size_of_headers
    for ptr, size in secs:
        spans.append((ptr, ptr + size))
        hashed += size

    # trailing data, excluding the signature blob at the very end
    tail = len(b) - cert_size
    if tail > hashed:
        spans.append((hashed, tail))
    return spans, cert_off, cert_size


def pe_hash(path):
    b = open(path, "rb").read()
    spans, _, _ = _regions(b)
    h = hashlib.sha256()
    for start, end in spans:
        if end < start or end > len(b):
            raise ValueError("malformed PE: span %d..%d outside %d bytes"
                             % (start, end, len(b)))
        h.update(b[start:end])
    return h.hexdigest()


def _cert_der(b, off, size):
    """the first WIN_CERTIFICATE's DER, using its own dwLength."""
    # the data-directory size covers the whole table -- 8-byte alignment padding
    # and any further WIN_CERTIFICATE entries included. the first certificate's
    # real length is dwLength, and reading to the directory size instead handed
    # back the DER plus its padding.
    if size < 8 or off + size > len(b):
        raise ValueError("certificate table out of range")
    dwlen = struct.unpack_from("<I", b, off)[0]
    if dwlen < 8 or dwlen > size:
        raise ValueError("bad WIN_CERTIFICATE length %d" % dwlen)
    return b[off + 8:off + dwlen]


def extract_sig(path, out):
    b = open(path, "rb").read()
    _, off, size = _regions(b)
    if not size:
        raise ValueError("image carries no signature")
    # WIN_CERTIFICATE: dwLength(4) wRevision(2) wCertificateType(2), then DER
    open(out, "wb").write(_cert_der(b, off, size))


# DER for the sha-256 algorithm OID, 2.16.840.1.101.3.4.2.1
_SHA256_OID = bytes.fromhex("0609608648016503040201")


def verify(path):
    """assert this hasher agrees with the signature already on the image.

    sbsign signed the authenticode digest, so that digest sits inside the
    PKCS#7 blob, in the DigestInfo of the SpcIndirectDataContent. read it out
    of that structure and compare.

    this used to be `if bytes.fromhex(want) not in der` -- a substring search.
    the certificate table is BY DEFINITION excluded from the authenticode hash,
    so those bytes are free space the image's author controls: make the hasher
    compute a digest of your choosing (lie about NumberOfSections), then write
    that digest anywhere in the blob, and the check passes. it was asking the
    image to vouch for itself. that is fine for an image we just built and
    worthless for `./build.sh revoke` on anyone else's -- which is the only
    caller that ever sees a foreign image, and the whole reason this exists.
    """
    b = open(path, "rb").read()
    _, off, size = _regions(b)
    if not size:
        raise ValueError("image carries no signature to check against")
    der = _cert_der(b, off, size)
    want = pe_hash(path)

    # DigestInfo ::= SEQUENCE { AlgorithmIdentifier, OCTET STRING }. the OID
    # also appears in the signerInfo's digestAlgorithm, where no OCTET STRING
    # follows it -- so look for the 32-byte one close behind, and require that
    # exactly one such digest exists.
    found = []
    i = der.find(_SHA256_OID)
    while i != -1:
        j = der.find(b"\x04\x20", i, i + 16)
        if j != -1:
            found.append(der[j + 2:j + 34])
        i = der.find(_SHA256_OID, i + 1)
    if len(found) != 1:
        raise ValueError("expected exactly one sha-256 DigestInfo in the "
                         "signature, found %d" % len(found))
    if found[0] != bytes.fromhex(want):
        raise ValueError("computed digest %s does not match the one the image "
                         "was signed over (%s) -- the hasher is wrong"
                         % (want, found[0].hex()))
    return want


if __name__ == "__main__":
    try:
        if len(sys.argv) == 4 and sys.argv[1] == "--sig":
            extract_sig(sys.argv[2], sys.argv[3])
        elif len(sys.argv) == 3 and sys.argv[1] == "--verify":
            print(verify(sys.argv[2]))
        elif len(sys.argv) == 2:
            print(pe_hash(sys.argv[1]))
        else:
            sys.exit("usage: pehash.py IMAGE | --verify IMAGE | --sig IMAGE OUT.der")
    # struct.error is not a ValueError, so a truncated image used to come out as
    # a traceback rather than a diagnosis -- on exactly the inputs where a clear
    # message matters most.
    except (OSError, ValueError, struct.error) as e:
        sys.exit("pehash: %s" % e)
