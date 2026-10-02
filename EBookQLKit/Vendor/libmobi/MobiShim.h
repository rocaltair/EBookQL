//
//  MobiShim.h
//  EBookQLKit / Vendor/libmobi
//
//  A very thin C shim over libmobi, so Swift never touches libmobi's structs.
//
//  Why this exists: exposing mobi.h and util.h directly to the Swift compiler (a
//  module map over those headers) makes Clang treat them as module headers while the
//  library's own .c files include them textually, and it fails with
//  "typedef redefinition with different types" in buffer.h. Keeping the module's
//  interface to this one self-contained header avoids that entirely, and it also
//  keeps the awkward parts - the EXTH walk, cp1252 conversion, raw buffers - in C,
//  where libmobi's types are natural.
//
//  Everything this header returns is heap-allocated UTF-8 and must be released with
//  MobiBookFreeString. libmobi itself is LGPL-3.0-or-later (see the LICENSE note in
//  libmobi/).
//

#ifndef EBookQL_MobiShim_h
#define EBookQL_MobiShim_h

#include <stddef.h>

/// Status codes. Deliberately not libmobi's MOBI_RET: Swift should not need libmobi's
/// headers to interpret them.
enum {
    MobiShimOK = 0,
    MobiShimEncrypted = 1,
    MobiShimUnsupported = 2,
    MobiShimCorrupt = 3,
    MobiShimIO = 4,
};

/// An open book. Opaque on purpose.
typedef struct MobiBook MobiBook;

/// Opens `path`. Returns NULL on failure and writes a MobiShim* code to `status`.
MobiBook *MobiBookOpen(const char *path, int *status);

/// Frees a book and everything it owns.
void MobiBookClose(MobiBook *book);

/// `<dc:title>`, or NULL. Heap UTF-8.
char *MobiBookTitle(MobiBook *book);

/// EXTH tag 100 (`<dc:creator>`), or NULL. Heap UTF-8.
char *MobiBookAuthor(MobiBook *book);

/// The book's whole reconstructed markup. Heap UTF-8; `status` receives a
/// MobiShim* code (MobiShimOK when a string comes back).
char *MobiBookContent(MobiBook *book, int *status);

/// Converts the four characters after `kindle:embed:` into a 0-based resource id,
/// exactly as libmobi does when it rewrites those references itself. Returns 0 when
/// the value cannot be decoded.
int MobiBookResourceUidFromEmbed(const char *fid, unsigned int *uid);

/// Looks up a resource by its 0-based id (the same id `kindle:embed:` and KF7's
/// `recindex` resolve to). Returns the byte count and writes the mime type into
/// `mime`; returns NULL when there is no such resource. The bytes belong to the book
/// - do not free them.
size_t MobiBookResource(MobiBook *book, unsigned int uid,
                        unsigned char **bytes, char *mime, size_t mimeSize);

/// How many resources the book carries (diagnostics only).
int MobiBookResourceCount(MobiBook *book);

/// How many table-of-contents entries the book's NCX index carries, or 0 when the book
/// has no NCX (or it cannot be read).
int MobiBookTocCount(MobiBook *book);

/// Describes one NCX entry.
///
/// `title` is heap UTF-8 and must be released with MobiBookFreeString. `level` is the
/// container's own rank for the entry. `offsetInText` is where the entry points, as a byte
/// offset into the book's decompressed markup - the same text `MobiBookContent` returns -
/// or -1 when the container gives no usable position. `parentIndex` is the index of this
/// entry's parent in the same flat list (both target forms the format uses collapse to
/// those two numbers; see the comment on the implementation). Returns 0 when there is no
/// such entry.
int MobiBookTocEntry(MobiBook *book, unsigned int index, char **title, unsigned int *level,
                     long *offsetInText, int *parentIndex);

/// Resolves a `kindle:pos:fid:XXXX:off:YYYYYYYYYY` reference to a byte offset in the
/// book's decompressed markup, the same coordinate system `MobiBookTocEntry` reports.
/// Both halves are base32. Returns -1 when the reference cannot be resolved.
long MobiBookTextOffsetForPosfid(MobiBook *book, const char *fid, const char *off);

/// Releases a string returned by any of the above.
void MobiBookFreeString(char *string);

#endif
