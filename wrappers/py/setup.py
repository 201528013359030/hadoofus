"""
This 'hadoofus' python module provides a client API for accessing instances
of the Apache Hadoop Distributed File System, as well as compatible
implementations.
"""

import os
from distutils import log
from distutils.core import setup
from distutils.command.build_clib import build_clib
from distutils.errors import DistutilsSetupError
from distutils.extension import Extension
from distutils.sysconfig import parse_makefile
from os.path import abspath, dirname, realpath, splitext
from glob import glob

if os.environ.get("CFLAGS") is None:
    os.environ["CFLAGS"] = ""

try:
    from Cython.Build import cythonize
except ImportError:
    def cythonize(extensions, **_ignore):
        for extension in extensions:
            sources = []
            for sfile in extension.sources:
                path, ext = splitext(sfile)
                if ext in ('.pyx', '.py'):
                    if extension.language == 'c++':
                        ext = '.cpp'
                    else:
                        ext = '.c'
                    sfile = path + ext
                sources.append(sfile)
            extension.sources[:] = sources
        return extensions

class build_libhadoofus_clib(build_clib):
    def build_library(self, lib_name, build_info):
        sources = build_info.get('sources')
        if sources is None or not isinstance(sources, (list, tuple)):
            raise DistutilsSetupError(
                "in 'libraries' option (library '%s'), "
                "'sources' must be present and must be "
                "a list of source filenames" % lib_name)
        sources = list(sources)

        log.info("building '%s' library", lib_name)

        # First, compile the source code to object files in the library
        # directory.  (This should probably change to putting object
        # files in a temporary build directory.)
        macros = build_info.get('macros')
        include_dirs = build_info.get('include_dirs')
        extra_args = build_info.get('extra_compile_preargs')
        objects = self.compiler.compile(sources,
                                        output_dir=self.build_temp,
                                        macros=macros,
                                        include_dirs=include_dirs,
                                        extra_preargs=extra_args,
                                        debug=self.debug)

        # Now "link" the object files together into a static library.
        # (On Unix at least, this isn't really linking -- it just
        # builds an archive.  Whatever.)
        self.compiler.create_static_lib(objects, lib_name,
                                        output_dir=self.build_clib,
                                        debug=self.debug)

    def build_libraries(self, libraries):
        for (lib_name, build_info) in libraries:
            self.build_library(lib_name, build_info)

# The root directory of the project
root_dir = realpath(dirname(abspath(__file__)) + "/../..")
# The C headers files shared between libhadoofus and the hadoofus.pyx
include_dirs = ["%s/include" % root_dir, "/usr/local/include"]

# The libhadoofus C library
libhadoofus = ("hadoofus", {
    "sources": glob("%s/src/*.c" % root_dir),
    "include_dirs": include_dirs,
    "extra_compile_preargs": "-fPIC -g -fvisibility=hidden -DNO_EXPORT_SYMS -std=gnu99".split(" ")
})

# The hadoofus python extension, compiled by Cython
hadoofus = Extension(
    name="hadoofus",
    sources=["hadoofus.pyx"],
    libraries=["protobuf-c", "z", "sasl2", "rt"],
    include_dirs=include_dirs,
)

setup(
    name="hadoofus",
    version="0",
    description="Python client API for HDFS",
    author="Conrad Meyer",
    author_email="conrad.meyer@isilon.com",
    long_description=__doc__,
    url="https://github.com/cemeyer/hadoofus",
    classifiers=[
        'Development Status :: 2 - Pre-Alpha',
        'Intended Audience :: Developers',
        'License :: OSI Approved :: MIT License',
        'Operating System :: POSIX',
        'Programming Language :: Cython',
        'Topic :: Software Development :: Libraries',
        'Topic :: System :: Filesystems',
        'Topic :: System :: Networking',
    ],
    platforms=['Posix'],
    license='MIT',
    ext_modules=cythonize([hadoofus]),
    libraries=[libhadoofus],
    cmdclass={
        'build_clib': build_libhadoofus_clib,
    }
)
