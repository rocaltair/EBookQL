//
//  MobiShim.c
//  EBookQLKit / Vendor/libmobi
//
//  See MobiShim.h for why this layer exists. Ported from MobiFile's MobiReader.m,
//  keeping the fixes that were made there: the file is opened by path (no NSFileHandle
//  plus fdopen double-ownership of one descriptor), libmobi's own return code is
//  preserved so "encrypted" can be told apart from "corrupt", and the per-record
//  buffer in libmobi is sized from the book rather than a fixed 4096 bytes.
//

#include "MobiShim.h"

#include <stdlib.h>
#include <string.h>

#include "mobi.h"
#include "util.h"
#include "index.h"

struct MobiBook {
    MOBIData *data;
    /// Kept because libmobi leaves each resource record's bytes on disk and remembers
    /// only where they are, so serving an image means reading them back.
    char *path;
    /// Parsed indices, built on first use: 0 = not tried, 1 = parsed, 2 = unavailable.
    MOBIIndx *ncx;
    int ncx_state;
    /// The fragment index, which a KF8 `pos:fid:` value indexes.
    MOBIIndx *frag;
    int frag_state;
};

/// Resource records are opaque to libmobi until something decodes them, so their type
/// is recovered from the file's own magic bytes. Only the kinds a book actually
/// embeds are named; anything else is served as-is.
static const char *mobi_shim_mime(const unsigned char *data, size_t size) {
    if (size >= 3 && data[0] == 0xff && data[1] == 0xd8 && data[2] == 0xff) { return "image/jpeg"; }
    if (size >= 8 && memcmp(data, "\x89PNG\r\n\x1a\n", 8) == 0) { return "image/png"; }
    if (size >= 4 && memcmp(data, "GIF8", 4) == 0) { return "image/gif"; }
    if (size >= 2 && data[0] == 'B' && data[1] == 'M') { return "image/bmp"; }
    return "application/octet-stream";
}

/// Reads one record's bytes back from the file when libmobi left them on disk.
static MOBIPdbRecord *mobi_shim_record(MobiBook *book, size_t seqnumber) {
    MOBIPdbRecord *record = mobi_get_record_by_seqnumber(book->data, seqnumber);
    if (record == NULL || record->data != NULL || record->size == 0) { return record; }

    unsigned char *bytes = malloc(record->size);
    FILE *file = bytes != NULL ? fopen(book->path, "rb") : NULL;
    if (file == NULL || fseek(file, (long)record->offset, SEEK_SET) != 0
        || fread(bytes, 1, record->size, file) != record->size) {
        if (file != NULL) { fclose(file); }
        free(bytes);
        return NULL;
    }
    fclose(file);
    record->data = bytes;
    return record;
}

/// Parses one INDX record into a fresh index, reading back every record it spans.
///
/// The index records are not in memory either (see mobi_shim_record): an INDX spans
/// `entries_count` further INDX records plus the CNCX record that follows them, and
/// libmobi reads straight through all of them. Reading one record short is what makes
/// this crash rather than fail, so the span is walked exactly.
static MOBIIndx *mobi_shim_parse_indx(MobiBook *book, size_t record) {
    MOBIPdbRecord *head = mobi_shim_record(book, record);
    if (head == NULL || head->data == NULL || head->size < 28) { return NULL; }

    const unsigned char *bytes = head->data;
    const size_t span = ((size_t)bytes[24] << 24) | ((size_t)bytes[25] << 16)
                      | ((size_t)bytes[26] << 8) | (size_t)bytes[27];
    if (span > 4096) { return NULL; }                          /* implausible: give up */
    for (size_t i = 1; i <= span + 1; i++) {
        mobi_shim_record(book, record + i);
    }

    MOBIIndx *indx = mobi_init_indx();
    if (indx == NULL) { return NULL; }
    if (mobi_parse_index(book->data, indx, record) != MOBI_SUCCESS) {
        mobi_free_indx(indx);
        return NULL;
    }
    return indx;
}

/// The book's NCX table of contents, parsed once.
static MOBIIndx *mobi_shim_ncx(MobiBook *book) {
    if (book->ncx_state != 0) { return book->ncx; }
    book->ncx_state = 2;                                       /* unavailable until parsed */
    if (book->data != NULL && mobi_exists_ncx(book->data)) {
        const size_t record = *book->data->mh->ncx_index + mobi_get_kf8offset(book->data);
        book->ncx = mobi_shim_parse_indx(book, record);
        if (book->ncx != NULL) { book->ncx_state = 1; }
    }
    return book->ncx;
}

/// The book's fragment index, parsed once. A KF8 `pos:fid:` value indexes this table,
/// not the flow or the skeleton directly.
static MOBIIndx *mobi_shim_frag(MobiBook *book) {
    if (book->frag_state != 0) { return book->frag; }
    book->frag_state = 2;
    if (book->data != NULL && mobi_exists_frag_indx(book->data)
        && book->data->mh->fragment_index != NULL
        && *book->data->mh->fragment_index != MOBI_NOTSET) {
        const size_t record = *book->data->mh->fragment_index + mobi_get_kf8offset(book->data);
        book->frag = mobi_shim_parse_indx(book, record);
        if (book->frag != NULL) { book->frag_state = 1; }
    }
    return book->frag;
}

static int mobi_shim_code(MOBI_RET code) {
    switch (code) {
        case MOBI_FILE_ENCRYPTED: return MobiShimEncrypted;
        case MOBI_FILE_UNSUPPORTED: return MobiShimUnsupported;
        case MOBI_DATA_CORRUPT: return MobiShimCorrupt;
        default: return MobiShimIO;
    }
}

/// libmobi hands back the bytes exactly as stored in the file; older books keep them
/// in cp1252, which is not valid UTF-8.
static int mobi_shim_is_utf8(const char *input, size_t length) {
    const unsigned char *bytes = (const unsigned char *)input;
    size_t index = 0;
    while (index < length) {
        unsigned char byte = bytes[index];
        size_t extra;
        if (byte < 0x80) { index += 1; continue; }
        else if ((byte & 0xE0) == 0xC0) { extra = 1; }
        else if ((byte & 0xF0) == 0xE0) { extra = 2; }
        else if ((byte & 0xF8) == 0xF0) { extra = 3; }
        else { return 0; }
        if (index + extra >= length) { return 0; }
        for (size_t offset = 1; offset <= extra; offset++) {
            if ((bytes[index + offset] & 0xC0) != 0x80) { return 0; }
        }
        index += extra + 1;
    }
    return 1;
}

static char *mobi_shim_string(const char *input, size_t length, const MOBIData *m) {
    if (input == NULL || length == 0) { return NULL; }

    if (mobi_shim_is_utf8(input, length)) {
        char *copy = malloc(length + 1);
        if (copy == NULL) { return NULL; }
        memcpy(copy, input, length);
        copy[length] = '\0';
        return copy;
    }

    if (m == NULL || !mobi_is_cp1252(m)) { return NULL; }

    /* Worst case: every input byte becomes a 3-byte UTF-8 sequence. */
    size_t out_length = 3 * length + 1;
    char *converted = malloc(out_length + 1);
    if (converted == NULL) { return NULL; }
    if (mobi_cp1252_to_utf8(converted, input, &out_length, length) != MOBI_SUCCESS || out_length == 0) {
        free(converted);
        return NULL;
    }
    converted[out_length] = '\0';
    return converted;
}

MobiBook *MobiBookOpen(const char *path, int *status) {
    if (status != NULL) { *status = MobiShimIO; }
    if (path == NULL) { return NULL; }

    MOBIData *data = mobi_init();
    if (data == NULL) { return NULL; }

    MOBI_RET loaded = mobi_load_filename(data, path);
    if (loaded != MOBI_SUCCESS) {
        mobi_free(data);
        if (status != NULL) { *status = mobi_shim_code(loaded); }
        return NULL;
    }

    MobiBook *book = calloc(1, sizeof(MobiBook));
    if (book == NULL) {
        mobi_free(data);
        return NULL;
    }
    book->data = data;
    /* Records are read back through this path when the page asks for an image. */
    book->path = strdup(path);
    if (book->path == NULL) {
        mobi_free(data);
        free(book);
        return NULL;
    }
    if (status != NULL) { *status = MobiShimOK; }
    return book;
}

void MobiBookClose(MobiBook *book) {
    if (book == NULL) { return; }
    /* The indices reference records owned by `data`, so they go first. */
    if (book->ncx != NULL) { mobi_free_indx(book->ncx); }
    if (book->frag != NULL) { mobi_free_indx(book->frag); }
    if (book->data != NULL) { mobi_free(book->data); }
    free(book->path);
    free(book);
}

int MobiBookResourceUidFromEmbed(const char *fid, unsigned int *uid) {
    if (fid == NULL || uid == NULL) { return 0; }
    uint32_t decoded = 0;
    if (mobi_base32_decode(&decoded, fid) != MOBI_SUCCESS) { return 0; }
    if (decoded == 0) { return 0; }
    /* libmobi treats these ids as 1-based. */
    *uid = (unsigned int)(decoded - 1);
    return 1;
}

size_t MobiBookResource(MobiBook *book, unsigned int uid,
                        unsigned char **bytes, char *mime, size_t mimeSize) {
    if (bytes != NULL) { *bytes = NULL; }
    if (mime != NULL && mimeSize > 0) { mime[0] = '\0'; }
    if (book == NULL || bytes == NULL || book->data == NULL) { return 0; }

    /* Resources are the records after the text. libmobi records only where each one
       sits in the file and leaves its bytes there, so a request reads it back.
       (Its own reconstruction path - mobi_parse_rawml - assumes the bytes are already
       in memory and faults on exactly this, which is why this reads records directly.) */
    const size_t first = mobi_get_first_resource_record(book->data);
    if (first == MOBI_NOTSET) { return 0; }

    MOBIPdbRecord *record = mobi_get_record_by_seqnumber(book->data, first + (size_t)uid);
    if (record == NULL || record->size == 0) { return 0; }

    if (record->data == NULL) {
        unsigned char *loaded = malloc(record->size);
        FILE *file = loaded != NULL ? fopen(book->path, "rb") : NULL;
        if (file == NULL || fseek(file, (long)record->offset, SEEK_SET) != 0
            || fread(loaded, 1, record->size, file) != record->size) {
            if (file != NULL) { fclose(file); }
            free(loaded);
            return 0;
        }
        fclose(file);
        /* Attached to the record so it is released together with the book. */
        record->data = loaded;
    }

    *bytes = record->data;
    if (mime != NULL && mimeSize > 0) {
        const char *type = mobi_shim_mime(record->data, record->size);
        strncpy(mime, type, mimeSize - 1);
        mime[mimeSize - 1] = '\0';
    }
    return record->size;
}

int MobiBookResourceCount(MobiBook *book) {
    if (book == NULL || book->data == NULL) { return -1; }
    const size_t first = mobi_get_first_resource_record(book->data);
    if (first == MOBI_NOTSET) { return 0; }
    int count = 0;
    while (mobi_get_record_by_seqnumber(book->data, first + (size_t)count) != NULL) { count++; }
    return count;
}

/// Maps a fragment id and an offset in it to a byte offset in the decompressed markup.
///
/// The fragment index entry's label is that fragment's absolute offset in the flow - the
/// same text these offsets are relative to. (libmobi's mobi_get_offset_by_posoff subtracts
/// the skeleton part's position only to get an offset *within* a part, so that
/// mobi_get_id_by_posoff can scan that part; for an absolute position there is nothing to
/// subtract.) Returns -1 when the fragment is not in the index.
static long mobi_shim_text_offset(MobiBook *book, uint32_t pos_fid, uint32_t pos_off) {
    MOBIIndx *frag = mobi_shim_frag(book);
    if (frag == NULL || (size_t)pos_fid >= frag->entries_count
        || frag->entries[pos_fid].label == NULL) { return -1; }
    return (long)strtoul(frag->entries[pos_fid].label, NULL, 10) + (long)pos_off;
}

long MobiBookTextOffsetForPosfid(MobiBook *book, const char *fid, const char *off) {
    if (book == NULL || fid == NULL || off == NULL) { return -1; }
    uint32_t pos_fid = 0, pos_off = 0;
    if (mobi_base32_decode(&pos_fid, fid) != MOBI_SUCCESS) { return -1; }
    if (mobi_base32_decode(&pos_off, off) != MOBI_SUCCESS) { return -1; }
    return mobi_shim_text_offset(book, pos_fid, pos_off);
}

int MobiBookTocCount(MobiBook *book) {
    if (book == NULL) { return 0; }
    MOBIIndx *ncx = mobi_shim_ncx(book);
    return ncx == NULL ? 0 : (int)ncx->entries_count;
}

int MobiBookTocEntry(MobiBook *book, unsigned int index, char **title, unsigned int *level,
                     long *offsetInText, int *parentIndex) {
    if (title != NULL) { *title = NULL; }
    if (level != NULL) { *level = 0; }
    if (offsetInText != NULL) { *offsetInText = -1; }
    if (parentIndex != NULL) { *parentIndex = -1; }
    if (book == NULL) { return 0; }

    MOBIIndx *ncx = mobi_shim_ncx(book);
    if (ncx == NULL || (size_t)index >= ncx->entries_count) { return 0; }
    MOBIIndexEntry *entry = &ncx->entries[index];

    uint32_t text_offset = 0;
    if (mobi_get_indxentry_tagvalue(&text_offset, entry, INDX_TAG_NCX_TEXT_CNCX) != MOBI_SUCCESS) {
        return 0;
    }
    if (title != NULL) {
        *title = mobi_get_cncx_string(ncx->cncx_record, text_offset);
    }
    if (level != NULL) {
        uint32_t value = 0;
        mobi_get_indxentry_tagvalue(&value, entry, INDX_TAG_NCX_LEVEL);
        *level = value;
    }

    /* The tree the container describes, rather than the level: a level is a rank here, and
       listing every part before every chapter is not a tree walk (see MOBIBackend.tree). */
    if (parentIndex != NULL) {
        uint32_t parent = 0;
        if (mobi_get_indxentry_tagvalue(&parent, entry, INDX_TAG_NCX_PARENT) == MOBI_SUCCESS
            && (size_t)parent < ncx->entries_count) {
            *parentIndex = (int)parent;
        }
    }

    /* Two target spellings, one destination: a byte offset into the decompressed text.
       Which tags carry it depends on the book's version, and reading the other set reads
       past the entry's tags, so this follows libmobi's own rule (opf.c). */
    long offset = -1;
    if (mobi_get_fileversion(book->data) >= 8) {
        uint32_t fid = 0, pos_off = 0;
        mobi_get_indxentry_tagvalue(&fid, entry, INDX_TAG_NCX_POSFID);
        mobi_get_indxentry_tagvalue(&pos_off, entry, INDX_TAG_NCX_POSOFF);
        offset = mobi_shim_text_offset(book, fid, pos_off);
    } else {
        uint32_t filepos = 0;
        mobi_get_indxentry_tagvalue(&filepos, entry, INDX_TAG_NCX_FILEPOS);
        offset = (long)filepos;
    }
    if (offsetInText != NULL) { *offsetInText = offset; }
    return 1;
}

char *MobiBookTitle(MobiBook *book) {
    if (book == NULL || book->data == NULL) { return NULL; }
    MOBIData *m = book->data;
    if (m->mh == NULL) { return NULL; }

    char buffer[4096];
    if (mobi_get_fullname(m, buffer, sizeof(buffer)) != MOBI_SUCCESS) { return NULL; }
    buffer[sizeof(buffer) - 1] = '\0';
    return mobi_shim_string(buffer, strlen(buffer), m);
}

char *MobiBookAuthor(MobiBook *book) {
    if (book == NULL || book->data == NULL) { return NULL; }
    MOBIData *m = book->data;

    for (MOBIExthHeader *header = m->eh; header != NULL; header = header->next) {
        if (header->tag != EXTH_AUTHOR || header->data == NULL || header->size == 0) { continue; }
        char *decoded = mobi_decode_exthstring(m, header->data, header->size);
        if (decoded == NULL) { continue; }
        char *author = mobi_shim_string(decoded, strlen(decoded), m);
        free(decoded);
        return author;
    }
    return NULL;
}

char *MobiBookContent(MobiBook *book, int *status) {
    if (status != NULL) { *status = MobiShimIO; }
    if (book == NULL || book->data == NULL) { return NULL; }
    MOBIData *m = book->data;

    size_t maxsize = mobi_get_text_maxsize(m);
    if (maxsize == 0) {
        if (status != NULL) { *status = MobiShimCorrupt; }
        return NULL;
    }

    size_t capacity = maxsize + 1;
    char *text = malloc(capacity);
    if (text == NULL) { return NULL; }
    text[0] = '\0';

    size_t length = maxsize;
    MOBI_RET result = mobi_get_rawml(m, text, &length);
    if (result != MOBI_SUCCESS) {
        free(text);
        if (status != NULL) { *status = mobi_shim_code(result); }
        return NULL;
    }

    char *content = NULL;
    /* A "replica" prefix means libmobi already produced UTF-8. */
    if (length >= 4 && memcmp(text, REPLICA_MAGIC, 4) != 0 && mobi_is_cp1252(m)) {
        size_t out_length = 3 * length + 1;
        char *converted = malloc(out_length + 1);
        if (converted != NULL) {
            if (mobi_cp1252_to_utf8(converted, text, &out_length, length) == MOBI_SUCCESS && out_length > 0) {
                converted[out_length] = '\0';
                content = converted;
            } else {
                free(converted);
            }
        }
    } else {
        if (length >= capacity) { length = capacity - 1; }
        text[length] = '\0';
        content = mobi_shim_string(text, length, m);
    }

    free(text);
    if (content == NULL) {
        if (status != NULL) { *status = MobiShimCorrupt; }
        return NULL;
    }
    if (status != NULL) { *status = MobiShimOK; }
    return content;
}

void MobiBookFreeString(char *string) {
    free(string);
}
