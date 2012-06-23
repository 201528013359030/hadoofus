from libc.stdint cimport int64_t, intptr_t, int16_t, uint16_t
from libc.stdlib cimport malloc, free
from libc.string cimport const_char

from cpython.bytes cimport PyBytes_FromStringAndSize

from chighlevel cimport hdfs_getProtocolVersion, hdfs_getBlockLocations, hdfs_create, \
        hdfs_append, hdfs_setReplication, hdfs_setPermission, hdfs_setOwner, \
        hdfs_abandonBlock, hdfs_addBlock, hdfs_complete, hdfs_rename, hdfs_delete, \
        hdfs_mkdirs, hdfs_getListing, hdfs_renewLease, hdfs_getStats, \
        hdfs_getPreferredBlockSize, hdfs_getFileInfo, hdfs_getContentSummary, \
        hdfs_setQuota, hdfs_fsync, hdfs_setTimes, hdfs_recoverLease, \
        hdfs_datanode_new, hdfs_datanode_delete
from clowlevel cimport hdfs_namenode, hdfs_namenode_init, hdfs_namenode_destroy, \
        hdfs_namenode_destroy_cb, hdfs_namenode_connect, hdfs_namenode_authenticate, \
        hdfs_datanode, hdfs_datanode_read_file, hdfs_datanode_read, hdfs_datanode_write, \
        hdfs_datanode_write_file, hdfs_datanode_connect, hdfs_namenode_get_msgno
from cobjects cimport CLIENT_PROTOCOL, hdfs_object_type, hdfs_object, hdfs_exception, \
        H_ACCESS_CONTROL_EXCEPTION, H_PROTOCOL_EXCEPTION, H_ALREADY_BEING_CREATED_EXCEPTION, \
        H_FILE_NOT_FOUND_EXCEPTION, H_IO_EXCEPTION, H_LEASE_EXPIRED_EXCEPTION, \
        H_LOCATED_BLOCKS, H_LOCATED_BLOCK, H_BLOCK, H_DATANODE_INFO, H_DIRECTORY_LISTING, \
        H_ARRAY_LONG, H_FILE_STATUS, H_CONTENT_SUMMARY, \
        hdfs_etype_to_string, hdfs_object_free, hdfs_array_datanode_info_new, \
        hdfs_array_datanode_info_append_datanode_info, hdfs_datanode_info_copy, \
        hdfs_array_long, hdfs_located_blocks, hdfs_located_block_copy, hdfs_located_block, \
        hdfs_block_new, hdfs_directory_listing, hdfs_file_status_new_ex
cimport clowlevel

import errno
import socket
import sys
import time

# Public constants from pydoofus
HADOOP_1_0 = 0x50

_WRITE_BLOCK_SIZE = 64*1024*1024
DATANODE_PROTO_AP_1_0 = clowlevel.DATANODE_AP_1_0
DATANODE_PROTO_CDH3 = clowlevel.DATANODE_CDH3
DATANODE_ERR_NO_CRCS = <char*>clowlevel.DATANODE_ERR_NO_CRCS

cdef bytes const_str_to_py(const_char* s):
    return <char*>s

# Exceptions from pydoofus
class DisconnectError(Exception):
    pass

class ProtocolException(Exception):
    def __init__(self, etype, msg):
        Exception.__init__(self, "%s: %s" % (etype, msg))
        self._etype = etype
        self._emessage = msg

class AccessControlException(ProtocolException):
    pass

class AlreadyBeingCreatedException(ProtocolException):
    pass

class FileNotFoundException(ProtocolException):
    pass

class IOException(ProtocolException):
    pass

class LeaseExpiredException(ProtocolException):
    pass

# Helper stuffs to raise a pydoofus exception from an hdfs_object exception:
cdef dict exception_types = {
        H_ACCESS_CONTROL_EXCEPTION: AccessControlException,
        H_PROTOCOL_EXCEPTION: ProtocolException,
        H_ALREADY_BEING_CREATED_EXCEPTION: AlreadyBeingCreatedException,
        H_FILE_NOT_FOUND_EXCEPTION: FileNotFoundException,
        H_IO_EXCEPTION: IOException,
        H_LEASE_EXPIRED_EXCEPTION: LeaseExpiredException,
        }

cdef raise_protocol_error(hdfs_object* ex):
    if ex.ob_type != H_PROTOCOL_EXCEPTION:
        raise AssertionError("bogus exception passed to raise_protocol_error")

    cdef hdfs_exception *h_ex = &ex._exception
    cdef bytes py_msg = h_ex._msg # copy message so we can free hdfs object
    etype = exception_types.get(h_ex._etype, ProtocolException)
    cdef bytes py_etype = const_str_to_py(hdfs_etype_to_string(h_ex._etype))

    hdfs_object_free(ex)
    raise etype(py_etype, py_msg)


cdef generic_iterable_getitem(iterable, v):
    cdef list res = []
    if type(v) is int:
        for i, e in enumerate(iterable):
            if i == v:
                return e
        raise IndexError("list index out of range")
    elif type(v) is slice:
        it = iter(xrange(v.start or 0, v.stop or sys.maxint, v.step or 1))
        try:
            nexti = next(it)
            for i, e in enumerate(iterable):
                if i == nexti:
                    res.append(e)
                    nexti = next(it)
        except StopIteration:
            pass
        return res
    else:
        raise TypeError("list indices must be integers, not %s" % type(v).__name__)


cdef str generic_repr(object o):
    cdef list attrs = [], orig_attrs
    cdef object t_method = type(dir)

    orig_attrs = dir(o)
    for oa in orig_attrs:
        if oa.startswith("_"):
            continue
        if type(getattr(o, oa)) is t_method:
            continue
        attrs.append(oa)

    cdef str res = o.__class__.__name__ + "("
    for i, at in enumerate(attrs):
        if i != 0:
            res += ", "
        res += at + "=" + repr(getattr(o, at))
    res += ")"

    return res


cdef class located_blocks:
    cdef hdfs_object* lbs

    cpdef readonly int size
    cpdef readonly bint being_written
    cpdef readonly list blocks

    def __init__(self):
        raise TypeError("This class cannot be instantiated from Python")

    def __cinit__(self):
        self.lbs = NULL

    cdef init(self, hdfs_object *o):
        assert o is not NULL
        assert o.ob_type == H_LOCATED_BLOCKS
        assert self.lbs is NULL

        self.lbs = o
        self.size = o._located_blocks._size
        self.being_written = o._located_blocks._being_written
        self.blocks = []
        for lb in self:
            self.blocks.append(lb)

    def __dealloc__(self):
        if self.lbs is not NULL:
            hdfs_object_free(self.lbs)

    def __iter__(self):
        cdef hdfs_located_blocks* lbs = &self.lbs._located_blocks
        cdef located_block py_lb

        for i in range(lbs._num_blocks):
            py_lb = located_block_build(hdfs_located_block_copy(lbs._blocks[i]))
            yield py_lb

    def __repr__(self):
        return generic_repr(self)

    def __getitem__(self, v):
        return generic_iterable_getitem(self, v)

    def __len__(self):
        return self.lbs._located_blocks._num_blocks

# Note: caller loses their C-level ref to the object
cdef located_blocks located_blocks_build(hdfs_object* o):
    cdef located_blocks res = located_blocks.__new__(located_blocks)
    res.init(o)
    return res


cdef class located_block:
    cdef hdfs_object* lb

    cpdef readonly int64_t offset
    cpdef readonly int64_t blockid
    cpdef readonly int64_t generation
    cpdef readonly int64_t len
    cpdef readonly list locations

    def __init__(self):
        raise TypeError("This class cannot be instantiated from Python")

    def __cinit__(self):
        self.lb = NULL

    cdef init(self, hdfs_object *o):
        assert o is not NULL
        assert o.ob_type == H_LOCATED_BLOCK
        assert self.lb is NULL

        self.lb = o
        self.offset = o._located_block._offset
        self.blockid = o._located_block._blockid
        self.generation = o._located_block._generation
        self.len = o._located_block._len
        self.locations = []
        for loc in self:
            self.locations.append(loc)

    cdef hdfs_object* get_lb(self):
        return self.lb

    def __dealloc__(self):
        if self.lb is not NULL:
            hdfs_object_free(self.lb)

    def __iter__(self):
        cdef hdfs_located_block* lb = &self.lb._located_block
        cdef datanode_info py_di

        for i in range(lb._num_locs):
            py_di = datanode_info_build(hdfs_datanode_info_copy(lb._locs[i]))
            yield py_di

    def __getitem__(self, v):
        return generic_iterable_getitem(self, v)

    def __len__(self):
        return self.lb._located_block._num_locs

    def __repr__(self):
        return generic_repr(self)

# Note: caller loses their C-level ref to the object
cdef located_block located_block_build(hdfs_object* o):
    cdef located_block res = located_block.__new__(located_block)
    res.init(o)
    return res


cdef hdfs_object* convert_located_block_to_block(located_block lb):
    assert lb is not None

    cdef hdfs_object* res = hdfs_block_new(lb.blockid, lb.len, lb.generation)
    return res


cdef class block:
    cdef hdfs_object* c_block

    cpdef readonly int64_t len
    cpdef readonly int64_t blockid
    cpdef readonly int64_t generation

    def __init__(self, copy):
        assert copy is not None
        assert type(copy) is located_block

        self.c_block = convert_located_block_to_block(copy)
        self.len = self.c_block._block._length
        self.blockid = self.c_block._block._blkid
        self.generation = self.c_block._block._generation

    def __cinit__(self):
        self.c_block = NULL

    def __dealloc__(self):
        if self.c_block is not NULL:
            hdfs_object_free(self.c_block)

    def __repr__(self):
        return generic_repr(self)


cdef class datanode_info:
    cdef hdfs_object* c_di

    cpdef readonly char* location
    cpdef readonly char* hostname
    cpdef readonly char* port
    cpdef readonly uint16_t ipc_port

    def __init__(self):
        raise TypeError("This class cannot be instantiated from Python")

    def __cinit__(self):
        self.c_di = NULL

    cdef init(self, hdfs_object *o):
        assert o is not NULL
        assert o.ob_type == H_DATANODE_INFO
        assert self.c_di is NULL

        self.c_di = o
        self.location = o._datanode_info._location
        self.hostname = o._datanode_info._hostname
        self.port = o._datanode_info._port
        self.ipc_port = o._datanode_info._namenodeport

    def __dealloc__(self):
        if self.c_di is not NULL:
            hdfs_object_free(self.c_di)

    def __repr__(self):
        return generic_repr(self)

# Note: caller loses their C-level ref to the object
cdef datanode_info datanode_info_build(hdfs_object* o):
    cdef datanode_info res = datanode_info.__new__(datanode_info)
    res.init(o)
    return res


cdef hdfs_object* file_status_copy(hdfs_object* fs):
    return hdfs_file_status_new_ex(
            fs._file_status._file,
            fs._file_status._size,
            fs._file_status._directory,
            fs._file_status._replication,
            fs._file_status._block_size,
            fs._file_status._mtime,
            fs._file_status._atime,
            fs._file_status._permissions,
            fs._file_status._owner,
            fs._file_status._group)


cdef class directory_listing:
    cdef hdfs_object* c_dl

    cpdef readonly list files

    def __init__(self):
        raise TypeError("This class cannot be instantiated from Python")

    def __cinit__(self):
        self.c_dl = NULL

    cdef init(self, hdfs_object *o):
        assert o is not NULL
        assert o.ob_type == H_DIRECTORY_LISTING
        assert self.c_dl is NULL

        self.c_dl = o
        self.files = []
        for fs in self:
            self.files.append(fs)

    def __dealloc__(self):
        if self.c_dl is not NULL:
            hdfs_object_free(self.c_dl)

    def __repr__(self):
        return generic_repr(self)

    def __str__(self):
        return "\n".join((str(fs) for fs in self))

    def __len__(self):
        return self.c_dl._directory_listing._num_files

    def __iter__(self):
        cdef hdfs_directory_listing* dl = &self.c_dl._directory_listing
        cdef file_status py_fs

        for i in range(dl._num_files):
            py_fs = file_status_build(file_status_copy(dl._files[i]))
            yield py_fs

    def __getitem__(self, v):
        return generic_iterable_getitem(self, v)

# Note: caller loses their C-level ref to the object
cdef directory_listing directory_listing_build(hdfs_object* o):
    cdef directory_listing res = directory_listing.__new__(directory_listing)
    res.init(o)
    return res


cdef str format_perm_triplet(int p):
    cdef str p1 = "r", p2 = "-", p3 = "-"
    if not p & 0x4:
        p1 = "-"
    if p & 0x2:
        p2 = "w"
    if p & 0x1:
        p3 = "x"
    return p1 + p2 + p3

cdef str format_perms(int perms, bint isdir):
    dirs = "-"
    if isdir:
        dirs = "d"
    return "%s%s%s%s" % (dirs, format_perm_triplet((perms >> 6) & 0x7), \
            format_perm_triplet((perms >> 3) & 0x7), \
            format_perm_triplet(perms & 0x7))

cdef str format_date(int64_t time_ms):
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(float(time_ms)/1000))

cdef str format_repl(bint isdir, int repl):
    if isdir:
        return "-"
    return str(repl)


cdef class file_status:
    cdef hdfs_object* c_fs

    cpdef readonly int64_t size
    cpdef readonly int64_t block_size
    cpdef readonly int64_t mtime
    cpdef readonly int64_t atime
    cpdef readonly char* name
    cpdef readonly char* owner
    cpdef readonly char* group
    cpdef readonly int16_t replication
    cpdef readonly int16_t permissions
    cpdef readonly bint is_directory

    def __init__(self):
        raise TypeError("This class cannot be instantiated from Python")

    def __cinit__(self):
        self.c_fs = NULL

    cdef init(self, hdfs_object *o):
        assert o is not NULL
        assert o.ob_type == H_FILE_STATUS
        assert self.c_fs is NULL

        self.c_fs = o
        self.size = o._file_status._size
        self.block_size = o._file_status._block_size
        self.mtime = o._file_status._mtime
        self.atime = o._file_status._atime
        self.name = o._file_status._file
        self.owner = o._file_status._owner
        self.group = o._file_status._group
        self.replication = o._file_status._replication
        self.permissions = o._file_status._permissions
        self.is_directory = o._file_status._directory

    def __dealloc__(self):
        if self.c_fs is not NULL:
            hdfs_object_free(self.c_fs)

    def __repr__(self):
        return generic_repr(self)

    def __str__(self):
        return "%s\t%s\t%s\t%s\t%s\t%s\t%s" % (
                format_perms(self.permissions, self.is_directory),
                format_repl(self.is_directory, self.replication),
                self.owner, self.group, self.size,
                format_date(self.mtime), self.name)

# Note: caller loses their C-level ref to the object
cdef file_status file_status_build(hdfs_object* o):
    cdef file_status res = file_status.__new__(file_status)
    res.init(o)
    return res


cdef class content_summary:
    cdef hdfs_object* c_cs

    cpdef readonly int64_t length
    cpdef readonly int64_t files
    cpdef readonly int64_t directories
    cpdef readonly int64_t quota

    def __init__(self):
        raise TypeError("This class cannot be instantiated from Python")

    def __cinit__(self):
        self.c_cs = NULL

    cdef init(self, hdfs_object *o):
        assert o is not NULL
        assert o.ob_type == H_CONTENT_SUMMARY

        self.c_cs = o
        self.length = o._content_summary._length
        self.files = o._content_summary._files
        self.directories = o._content_summary._dirs
        self.quota = o._content_summary._quota

    def __dealloc__(self):
        if self.c_cs is not NULL:
            hdfs_object_free(self.c_cs)

    def __repr__(self):
        return generic_repr(self)

# Note: caller loses their C-level ref to the object
cdef content_summary content_summary_build(hdfs_object* o):
    cdef content_summary res = content_summary.__new__(content_summary)
    res.init(o)
    return res


cdef hdfs_object* convert_list_to_array_datanode_info(list l_di):
    assert l_di is not None
    cdef hdfs_object* res
    cdef datanode_info di
    cdef hdfs_object* di_copy

    res = hdfs_array_datanode_info_new()
    try:
        for e in l_di:
            di = e
            di_copy = hdfs_datanode_info_copy(di.c_di)
            hdfs_array_datanode_info_append_datanode_info(res, di_copy)
    except:
        hdfs_object_free(res)
        raise

    return res


cdef list convert_array_long_to_list(hdfs_object* o):
    assert o
    assert o.ob_type == H_ARRAY_LONG
    cdef list res = []
    cdef hdfs_array_long* c_arr = &o._array_long

    cdef object v
    for i in range(c_arr._len):
        v = c_arr._vals[i]
        res.append(v)

    hdfs_object_free(o)

    return res


# pydoofus-esque rpc class!
cdef class rpc:
    cdef hdfs_namenode nn
    cdef bint closed

    cpdef readonly bytes _ipc_proto
    cpdef readonly str address
    cpdef readonly int protocol
    cpdef readonly str user

    def __cinit__(self):
        hdfs_namenode_init(&self.nn)

    def __dealloc__(self):
        hdfs_namenode_destroy(&self.nn, NULL)

    def __init__(self, addr, protocol=HADOOP_1_0, user=None):
        self._ipc_proto = const_str_to_py(CLIENT_PROTOCOL)
        self.closed = False

        if user is None:
            user = "root"

        self.address = addr
        self.protocol = protocol
        self.user = user

        cdef char* c_addr = addr
        cdef char* c_port = "8020"
        cdef const_char* err
        cdef bytes py_err

        err = hdfs_namenode_connect(&self.nn, c_addr, c_port)
        if err is not NULL:
            py_err = const_str_to_py(err)
            raise socket.error(errno.ECONNREFUSED, py_err)

        cdef char* c_user = user

        err = hdfs_namenode_authenticate(&self.nn, c_user)
        if err is not NULL:
            py_err = const_str_to_py(err)
            raise socket.error(errno.EPIPE, py_err)

        # pydoofus checks getProtocolVersion(), we should too.
        assert 61 == self.getProtocolVersion(61)

    def __repr__(self):
        return generic_repr(self)

    property num_calls:
        def __get__(self):
            return hdfs_namenode_get_msgno(&self.nn)

    # TODO plumb close() semantics through C-level api.
    # double-close() is fine, but operations must somehow raise
    # ValueError("X on closed handle") when called on a closed handle.

    cpdef int64_t getProtocolVersion(self, int64_t version, char* protostr=CLIENT_PROTOCOL):
        cdef int64_t res
        cdef hdfs_object* ex = NULL

        res = hdfs_getProtocolVersion(&self.nn, protostr, version, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

        return res

    cpdef located_blocks getBlockLocations(self, char* path, int64_t offset=0, int64_t length=4LL*1024*1024*1024):
        cdef hdfs_object* ex = NULL
        cdef hdfs_object* res

        res = hdfs_getBlockLocations(&self.nn, path, offset, length, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

        return located_blocks_build(res)

    cpdef create(self, char *path, int16_t perms, char *client, bint can_overwrite=False, int16_t replication=1, int64_t blocksize=_WRITE_BLOCK_SIZE, bint create_parent=True):
        cdef hdfs_object* ex = NULL

        hdfs_create(&self.nn, path, perms, client, can_overwrite, create_parent, replication, blocksize, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

    cpdef located_block append(self, char *path, char *client):
        cdef hdfs_object* ex = NULL
        cdef hdfs_object* res

        res = hdfs_append(&self.nn, path, client, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

        return located_block_build(res)

    cpdef bint setReplication(self, char *path, int16_t replication):
        cdef hdfs_object* ex = NULL
        cdef bint res

        res = hdfs_setReplication(&self.nn, path, replication, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

        return res

    cpdef setPermission(self, char *path, int16_t perms):
        cdef hdfs_object* ex = NULL

        hdfs_setPermission(&self.nn, path, perms, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

    cpdef setOwner(self, char *path, char *owner, char *group):
        cdef hdfs_object* ex = NULL

        hdfs_setOwner(&self.nn, path, owner, group, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

    cpdef abandonBlock(self, block bl, char *path, char *client):
        cdef hdfs_object* ex = NULL

        hdfs_abandonBlock(&self.nn, bl.c_block, path, client, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

    cpdef located_block addBlock(self, char *path, char *client, list excluded=None):
        cdef hdfs_object* ex = NULL
        cdef hdfs_object* res
        cdef hdfs_object* c_excl = NULL

        if excluded is not None:
            c_excl = convert_list_to_array_datanode_info(excluded)

        res = hdfs_addBlock(&self.nn, path, client, c_excl, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

        return located_block_build(res)

    cpdef bint complete(self, char *path, char *client):
        cdef hdfs_object* ex = NULL
        cdef bint res

        res = hdfs_complete(&self.nn, path, client, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

        return res

    cpdef bint rename(self, char *src, char *dst):
        cdef hdfs_object* ex = NULL
        cdef bint res

        res = hdfs_rename(&self.nn, src, dst, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

        return res

    cpdef bint delete(self, char *path, bint can_recurse=False):
        cdef hdfs_object* ex = NULL
        cdef bint res

        res = hdfs_delete(&self.nn, path, can_recurse, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

        return res

    cpdef bint mkdirs(self, char *path, int16_t perms):
        cdef hdfs_object* ex = NULL
        cdef bint res

        res = hdfs_mkdirs(&self.nn, path, perms, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

        return res

    cpdef directory_listing getListing(self, char *path):
        cdef hdfs_object* ex = NULL
        cdef hdfs_object* res

        res = hdfs_getListing(&self.nn, path, NULL, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

        return directory_listing_build(res)

    cpdef renewLease(self, char *client):
        cdef hdfs_object* ex = NULL

        hdfs_renewLease(&self.nn, client, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

    cpdef list getStats(self):
        cdef hdfs_object* ex = NULL
        cdef hdfs_object* res

        res = hdfs_getStats(&self.nn, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

        return convert_array_long_to_list(res)

    cpdef int64_t getPreferredBlockSize(self, char *path):
        cdef hdfs_object* ex = NULL
        cdef int64_t res

        res = hdfs_getPreferredBlockSize(&self.nn, path, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

        return res

    cpdef file_status getFileInfo(self, char *path):
        cdef hdfs_object* ex = NULL
        cdef hdfs_object* res

        res = hdfs_getFileInfo(&self.nn, path, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

        return file_status_build(res)

    cpdef content_summary getContentSummary(self, char *path):
        cdef hdfs_object* ex = NULL
        cdef hdfs_object* res

        res = hdfs_getContentSummary(&self.nn, path, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

        return content_summary_build(res)

    cpdef setQuota(self, char *path, int64_t nsquota, int64_t dsquota):
        cdef hdfs_object* ex = NULL

        hdfs_setQuota(&self.nn, path, nsquota, dsquota, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

    cpdef fsync(self, char *path, char *client):
        cdef hdfs_object* ex = NULL

        hdfs_fsync(&self.nn, path, client, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

    cpdef setTimes(self, char *path, int64_t mtime, int64_t atime):
        cdef hdfs_object* ex = NULL

        hdfs_setTimes(&self.nn, path, mtime, atime, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

    cpdef bint recoverLease(self, char *path, char *client):
        cdef hdfs_object* ex = NULL
        cdef bint res

        res = hdfs_recoverLease(&self.nn, path, client, &ex)
        if ex is not NULL:
            raise_protocol_error(ex)

        return res


# TODO handle the connecting ourselves so we can report:
# - num. failed datanode attempts (and list)
# - actual datanode we are connected to
cdef class data:
    cdef hdfs_datanode* dn

    cpdef readonly int protocol
    cpdef readonly bytes client
    cpdef readonly int size

    def __cinit__(self):
        self.dn = NULL

    def __init__(self, lb, client, proto=DATANODE_PROTO_AP_1_0):
        assert lb is not None
        assert type(lb) is located_block

        self.size = lb.len
        self.client = str(client)

        cdef char* c_client = self.client
        cdef int c_proto = int(proto)
        cdef const_char* err = NULL

        assert c_proto is DATANODE_PROTO_AP_1_0 or c_proto is DATANODE_PROTO_CDH3
        self.protocol = c_proto

        self.dn = hdfs_datanode_new(located_block.get_lb(lb), c_client, c_proto, &err)
        if self.dn is NULL:
            raise ValueError("Failed to create datanode connection: %s" % \
                    const_str_to_py(err))

    def __dealloc__(self):
        if self.dn is not NULL:
            hdfs_datanode_delete(self.dn)

    def __repr__(self):
        return generic_repr(self)

    def write(self, bytes data, bint sendcrcs=False):
        cdef const_char* err
        cdef char* inp = data

        err = hdfs_datanode_write(self.dn, inp, len(data), sendcrcs)
        if err is not NULL:
            raise Exception(const_str_to_py(err))

    def read(self, bint verifycrcs=False):
        cdef const_char* err
        cdef bytes res = PyBytes_FromStringAndSize(NULL, self.size)
        cdef char* buf = <char*>res

        assert self.size > 0

        err = hdfs_datanode_read(self.dn, 0, self.size, buf, verifycrcs)
        if err is not NULL:
            raise Exception(const_str_to_py(err))

        return res
