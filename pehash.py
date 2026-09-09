#!/usr/bin/env python3
"""authenticode sha-256 of a PE image -- the digest UEFI matches against dbx.

this is NOT sha256sum of the file. the firmware hashes the image with three
regions excluded: the header checksum, the certificate-table directory entry,
and the attached signature itself. hashing the whole file instead produces a
number that never matches anything, and a dbx entry that silently revokes
nothing -- which looks exactly like a dbx entry that works.

three independent checks keep this honest, because a wrong hash here fails open:
  G21  the digest this computes must equal the one inside the image's own
       PKCS#7 signature (sbsign signed that digest, so it is ground truth)
  G44  an image carrying a planted copy of a wrong digest must still be refused
  A11  a revoked image must actually be refused by the firmware, in a vm
"""
import hashlib
import struct
import sys


def _regions(b):
    """(spans_to_hash, cert_offset, cert_size) per the authenticode spec."""
    if b[:2] != b"MZ":
        raise ValueError("not a PE image (no MZ)")
    pe = struct.unpack_from("<I", b, 0x3C)[0]
    if b[pe:pe + 4] != b"PE\0\0":
        raise ValueError("not a PE image (no PE signature)")

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


# --- minimal DER, enough to walk one authenticode signature -------------------
#
# the digest we revoke has exactly one legitimate home: SpcIndirectDataContent's
# messageDigest, which is the number sbsign signed. searching the whole PKCS#7
# blob for it instead -- as this file used to -- accepts a match anywhere,
# including a certificate body, an unauthenticated attribute, or padding, all of
# which come from the image and none of which are signed. an image can therefore
# carry a planted copy of its own wrong digest and pass. so we walk to the one
# field that counts and demand equality.

OID_SIGNED_DATA = "1.2.840.113549.1.7.2"
OID_SPC_INDIRECT = "1.3.6.1.4.1.311.2.1.4"
OID_SHA256 = "2.16.840.1.101.3.4.2.1"


def _tlv(b, i):
    """the DER element at b[i:] -> (tag, value_start, value_end, next_index)."""
    if i + 2 > len(b):
        raise ValueError("DER: element runs past the blob")
    tag = b[i]
    if tag & 0x1F == 0x1F:
        raise ValueError("DER: multi-byte tags are not used here")
    n = b[i + 1]
    i += 2
    if n & 0x80:
        k = n & 0x7F
        if k == 0 or k > 4 or i + k > len(b):
            raise ValueError("DER: bad length encoding")
        n = int.from_bytes(b[i:i + k], "big")
        i += k
    if i + n > len(b):
        raise ValueError("DER: length runs past the blob")
    return tag, i, i + n, i + n


def _kids(b, s, e):
    """every element between s and e, in order."""
    out = []
    while s < e:
        tag, vs, ve, s = _tlv(b, s)
        out.append((tag, vs, ve))
    if s != e:
        raise ValueError("DER: children overrun their parent")
    return out


def _seq(b, s, e, n):
    """the n children of a constructed element, or a clear error."""
    k = _kids(b, s, e)
    if len(k) < n:
        raise ValueError("DER: expected %d elements, found %d" % (n, len(k)))
    return k


def _oid(b, s, e):
    """an OBJECT IDENTIFIER's value bytes as a dotted string."""
    if e <= s:
        raise ValueError("DER: empty OID")
    parts = [str(b[s] // 40), str(b[s] % 40)]
    v = 0
    for c in b[s + 1:e]:
        v = (v << 7) | (c & 0x7F)
        if not c & 0x80:
            parts.append(str(v))
            v = 0
    return ".".join(parts)


def _expect(b, kid, tag, what):
    if kid[0] != tag:
        raise ValueError("DER: %s has tag 0x%02x, expected 0x%02x"
                         % (what, kid[0], tag))
    return kid[1], kid[2]


def signed_digest(der):
    """the authenticode digest sbsign actually signed, out of the one field
    that holds it: SignedData.contentInfo -> SpcIndirectDataContent.messageDigest.
    """
    tag, s, e, _ = _tlv(der, 0)                       # ContentInfo
    if tag != 0x30:
        raise ValueError("DER: signature is not a SEQUENCE")
    ci = _seq(der, s, e, 2)
    s, e = _expect(der, ci[0], 0x06, "ContentInfo.contentType")
    if _oid(der, s, e) != OID_SIGNED_DATA:
        raise ValueError("DER: not a PKCS#7 signedData")
    s, e = _expect(der, ci[1], 0xA0, "ContentInfo.content")

    sd = _seq(der, *_expect(der, _seq(der, s, e, 1)[0], 0x30, "SignedData"), 3)
    s, e = _expect(der, sd[2], 0x30, "SignedData.contentInfo")
    eci = _seq(der, s, e, 2)
    s, e = _expect(der, eci[0], 0x06, "contentInfo.contentType")
    if _oid(der, s, e) != OID_SPC_INDIRECT:
        raise ValueError("DER: signature does not carry SpcIndirectDataContent")
    s, e = _expect(der, eci[1], 0xA0, "contentInfo.content")

    spc = _seq(der, *_expect(der, _seq(der, s, e, 1)[0], 0x30,
                             "SpcIndirectDataContent"), 2)
    di = _seq(der, *_expect(der, spc[1], 0x30, "DigestInfo"), 2)
    s, e = _expect(der, di[0], 0x30, "DigestInfo.digestAlgorithm")
    s, e = _expect(der, _seq(der, s, e, 1)[0], 0x06, "digestAlgorithm.algorithm")
    if _oid(der, s, e) != OID_SHA256:
        raise ValueError("DER: signature digest is %s, not sha-256"
                         % _oid(der, s, e))
    s, e = _expect(der, di[1], 0x04, "DigestInfo.digest")
    if e - s != 32:
        raise ValueError("DER: sha-256 digest is %d bytes" % (e - s))
    return der[s:e].hex()


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


def extract_sig(path, out):
    b = open(path, "rb").read()
    _, off, size = _regions(b)
    if not size:
        raise ValueError("image carries no signature")
    # WIN_CERTIFICATE: dwLength(4) wRevision(2) wCertificateType(2), then DER
    open(out, "wb").write(b[off + 8:off + size])


def verify(path):
    """assert this hasher agrees with the signature already on the image.

    sbsign signed the authenticode digest, so that digest sits in the image's
    own PKCS#7 blob, in SpcIndirectDataContent. if our number is not that exact
    field, our number is wrong -- and every dbx entry built from it would revoke
    nothing while looking like revocation that works.
    """
    b = open(path, "rb").read()
    _, off, size = _regions(b)
    if not size:
        raise ValueError("image carries no signature to check against")
    signed = signed_digest(b[off + 8:off + size])
    want = pe_hash(path)
    if want != signed:
        raise ValueError("computed digest %s does not match the digest in the "
                         "image's own signature (%s) -- the hasher is wrong or "
                         "the image was altered after signing" % (want, signed))
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
    except (OSError, ValueError) as e:
        sys.exit("pehash: %s" % e)
